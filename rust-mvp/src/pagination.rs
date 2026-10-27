use crate::{
    extractor::{extract, Work},
    Error, Result,
};
use serde_json::Value;
use std::collections::HashSet;

pub struct Page {
    pub works: Vec<Work>,
    pub cursor: Option<u64>,
    pub more: bool,
}
impl Page {
    pub fn parse(body: &[u8]) -> Result<Self> {
        let v: Value = serde_json::from_slice(body).map_err(|_| Error::Challenge)?;
        match v["status_code"].as_i64() {
            Some(0) => (),
            Some(_) => return Err(Error::Access),
            None => return Err(Error::Schema),
        }
        if ["verify_url", "captcha", "verify_info"]
            .iter()
            .any(|k| v.get(k).is_some_and(|x| !x.is_null() && x != ""))
        {
            return Err(Error::Challenge);
        }
        let works = v["aweme_list"]
            .as_array()
            .filter(|a| a.len() <= 1000)
            .ok_or(Error::Schema)?
            .iter()
            .map(extract)
            .collect::<Result<Vec<_>>>()?;
        let more = match &v["has_more"] {
            Value::Bool(b) => *b,
            Value::Number(n) if n.as_u64() == Some(0) => false,
            Value::Number(n) if n.as_u64() == Some(1) => true,
            _ => return Err(Error::Schema),
        };
        Ok(Self {
            works,
            cursor: v["max_cursor"].as_u64(),
            more,
        })
    }
}
pub struct Pagination {
    pub cursor: u64,
    pub works: Vec<Work>,
    pub duplicates: usize,
    pub pages: usize,
    pub stop_reason: &'static str,
    limit: usize,
    cursors: HashSet<u64>,
    ids: HashSet<String>,
}
impl Pagination {
    pub fn new(limit: usize) -> Result<Self> {
        if !(1..=100).contains(&limit) {
            return Err(Error::Scope);
        }
        Ok(Self {
            cursor: 0,
            works: vec![],
            duplicates: 0,
            pages: 0,
            stop_reason: "CONTINUE",
            limit,
            cursors: HashSet::from([0]),
            ids: HashSet::new(),
        })
    }
    pub fn advance(&mut self, page: Page) -> Result<bool> {
        if self.stop_reason != "CONTINUE" {
            return Err(Error::Cursor);
        }
        if page.more
            && (page.works.is_empty()
                || page
                    .cursor
                    .is_none_or(|c| c == 0 || self.cursors.contains(&c)))
        {
            return Err(Error::Cursor);
        }
        let before = self.works.len();
        for w in page.works {
            if self.ids.insert(w.id.clone()) {
                self.works.push(w);
            } else {
                self.duplicates += 1;
            }
        }
        self.pages += 1;
        if page.more && before == self.works.len() {
            return Err(Error::Cursor);
        }
        if !page.more {
            self.stop_reason = "SERVER_EXHAUSTED";
            return Ok(false);
        }
        self.cursor = page.cursor.ok_or(Error::Cursor)?;
        self.cursors.insert(self.cursor);
        if self.pages == self.limit {
            self.stop_reason = "PAGE_LIMIT_REACHED";
            return Ok(false);
        }
        Ok(true)
    }
}
