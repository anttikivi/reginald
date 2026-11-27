use std::{
    io::{self, Write},
    mem,
    sync::{Mutex, MutexGuard, PoisonError},
};

use clap::builder::{PossibleValuesParser, TypedValueParser};
use log::{Level, LevelFilter, Log};
use serde::{Deserialize, Deserializer, de};

const LEVEL_NAMES: [&str; 6] = ["off", "error", "warn", "info", "debug", "trace"];

static LOGGER: Logger = Logger {
    state: Mutex::new(State::new()),
};

struct Logger {
    state: Mutex<State>,
}

impl Logger {
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Log for Logger {
    fn enabled(&self, m: &log::Metadata) -> bool {
        m.level() <= log::max_level()
    }

    fn log(&self, r: &log::Record) {
        if !self.enabled(r.metadata()) {
            return;
        }

        if let Some(line) = self.state().record(r.level(), format_record(r)) {
            let _ = io::stderr().lock().write_all(line.as_bytes());
        }
    }

    fn flush(&self) {
        let _ = io::stderr().flush();
    }
}

enum State {
    Buffering {
        level: LevelFilter,
        buf: Vec<(Level, String)>,
    },
    Direct,
}

impl State {
    const fn new() -> Self {
        Self::Buffering {
            level: LevelFilter::Warn,
            buf: Vec::new(),
        }
    }

    fn finish_buffering(&mut self) -> Option<(LevelFilter, Vec<String>)> {
        match mem::replace(self, Self::Direct) {
            Self::Buffering { level, buf } => {
                let lines = buf
                    .into_iter()
                    .filter(|(l, _)| *l <= level)
                    .map(|(_, line)| line)
                    .collect();
                Some((level, lines))
            }
            Self::Direct => None,
        }
    }

    fn record(&mut self, level: Level, line: String) -> Option<String> {
        match self {
            Self::Buffering { buf, .. } => {
                buf.push((level, line));
                None
            }
            Self::Direct => Some(line),
        }
    }

    fn set_level(&mut self, new: LevelFilter) {
        if let Self::Buffering { level, .. } = self {
            *level = new;
        }
    }
}

/// Initializes the logger. Every message is buffered until calling
/// [`finish_buffering`].
pub fn init() {
    log::set_logger(&LOGGER).expect("logger is initialized once");
    log::set_max_level(LevelFilter::Trace);
}

/// Sets the level the buffered records are filtered with. It has no effect
/// after [`finish_buffering`].
pub fn set_level(level: LevelFilter) {
    LOGGER.state().set_level(level);
}

/// Writes the buffered logger records that pass the level and switches to
/// direct log output.
pub fn finish_buffering() {
    let mut state = LOGGER.state();
    if let Some((level, buf)) = state.finish_buffering() {
        log::set_max_level(level);
        let mut stderr = io::stderr().lock();
        for line in buf {
            let _ = stderr.write_all(line.as_bytes());
        }
    }
}

pub fn parse_level_filter(s: &str) -> Result<LevelFilter, String> {
    if LEVEL_NAMES.contains(&s) {
        Ok(s.parse()
            .expect("LEVEL_NAMES contains valid LevelFilter values"))
    } else {
        Err(format!("value \"{s}\" is not a valid log level"))
    }
}

pub fn deserialize_level_filter<'de, D>(d: D) -> Result<LevelFilter, D::Error>
where
    D: Deserializer<'de>,
{
    let s = String::deserialize(d)?;
    parse_level_filter(&s).map_err(de::Error::custom)
}

pub fn level_filter_parser() -> impl TypedValueParser<Value = LevelFilter> {
    PossibleValuesParser::new(LEVEL_NAMES)
        .map(|s| parse_level_filter(&s).expect("clap validates the value"))
}

fn format_record(r: &log::Record) -> String {
    use std::fmt::Write;

    let origin = match r.target() {
        t if t == "reginald" || t.starts_with("reginald::") => "reginald",
        t => t,
    };

    let level = match r.level() {
        Level::Error => "error",
        Level::Warn => "warn",
        Level::Info => "info",
        Level::Debug => "debug",
        Level::Trace => "trace",
    };

    let mut line = String::new();

    if origin != "reginald" {
        let _ = writeln!(line, "[{level}] [{origin}] {}", r.args());
    } else {
        let _ = writeln!(line, "[{level}] {}", r.args());
    }

    line
}

#[cfg(test)]
mod tests {
    use super::*;

    const NAMES: [(&str, LevelFilter); 6] = [
        ("off", LevelFilter::Off),
        ("error", LevelFilter::Error),
        ("warn", LevelFilter::Warn),
        ("info", LevelFilter::Info),
        ("debug", LevelFilter::Debug),
        ("trace", LevelFilter::Trace),
    ];

    #[test]
    fn level_names_are_complete_and_in_order() {
        let expected: Vec<_> = NAMES.iter().map(|(name, _)| *name).collect();
        assert_eq!(LEVEL_NAMES, expected[..]);
    }

    #[test]
    fn level_names_parse_to_their_filter() {
        for (name, filter) in NAMES {
            assert_eq!(parse_level_filter(name), Ok(filter), "{name}");
        }
    }

    #[test]
    fn level_names_are_case_sensitive() {
        assert!(parse_level_filter("DEBUG").is_err());
        assert!(parse_level_filter("Warn").is_err());
    }

    #[test]
    fn unknown_level_names_are_rejected() {
        assert_eq!(
            parse_level_filter("loud"),
            Err("value \"loud\" is not a valid log level".to_owned())
        );
    }

    fn lines(state: &mut State) -> Vec<String> {
        state.finish_buffering().unwrap().1
    }

    #[test]
    fn default_level_is_warn() {
        let mut state = State::new();
        state.record(Level::Warn, "w".into());
        state.record(Level::Info, "i".into());
        assert_eq!(lines(&mut state), ["w"]);
    }

    #[test]
    fn buffered_records_use_the_last_set_level() {
        let mut state = State::new();
        state.record(Level::Debug, "d".into());
        state.record(Level::Trace, "t".into());
        state.set_level(LevelFilter::Error);
        state.set_level(LevelFilter::Debug);
        assert_eq!(lines(&mut state), ["d"]);
    }

    #[test]
    fn records_are_written_directly_after_finish_buffering() {
        let mut state = State::new();
        assert_eq!(state.finish_buffering(), Some((LevelFilter::Warn, vec![])));
        assert_eq!(state.record(Level::Info, "i".into()), Some("i".into()));
    }

    #[test]
    fn finishing_twice_does_nothing() {
        let mut state = State::new();
        state.finish_buffering();
        assert_eq!(state.finish_buffering(), None);
    }
}
