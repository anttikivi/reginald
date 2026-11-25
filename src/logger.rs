use std::io::{self, Write};

use clap::{ValueEnum, builder::PossibleValue};
use log::{Level, LevelFilter, Log};

static LOGGER: Logger = Logger;

#[derive(Clone, Debug)]
pub struct LogLevel(LevelFilter);

impl ValueEnum for LogLevel {
    fn value_variants<'a>() -> &'a [Self] {
        &[
            Self(LevelFilter::Off),
            Self(LevelFilter::Error),
            Self(LevelFilter::Warn),
            Self(LevelFilter::Info),
            Self(LevelFilter::Debug),
            Self(LevelFilter::Trace),
        ]
    }

    fn to_possible_value(&self) -> Option<clap::builder::PossibleValue> {
        Some(PossibleValue::new(match self.0 {
            LevelFilter::Off => "off",
            LevelFilter::Error => "error",
            LevelFilter::Warn => "warn",
            LevelFilter::Info => "info",
            LevelFilter::Debug => "debug",
            LevelFilter::Trace => "trace",
        }))
    }
}

impl From<LogLevel> for LevelFilter {
    fn from(value: LogLevel) -> Self {
        value.0
    }
}

struct Logger;

impl Log for Logger {
    fn enabled(&self, m: &log::Metadata) -> bool {
        m.level() <= log::max_level()
    }

    fn log(&self, r: &log::Record) {
        if !self.enabled(r.metadata()) {
            return;
        }

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

        if origin != "reginald" {
            let _ = writeln!(io::stderr().lock(), "[{level}] [{origin}] {}", r.args());
        } else {
            let _ = writeln!(io::stderr().lock(), "[{level}] {}", r.args());
        }
    }

    fn flush(&self) {
        let _ = io::stderr().flush();
    }
}

pub fn init(l: LevelFilter) {
    log::set_logger(&LOGGER).expect("logger is initialized once");
    log::set_max_level(l);
}

pub fn resolve_level_filter(flag: Option<LogLevel>, verbose: u8, quiet: bool) -> LevelFilter {
    if quiet {
        return LevelFilter::Error;
    }

    match verbose {
        0 => {}
        1 => return LevelFilter::Info,
        2 => return LevelFilter::Debug,
        _ => return LevelFilter::Trace,
    }

    if let Some(level) = flag {
        return level.into();
    }

    LevelFilter::Off
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

    fn resolve(flag: Option<LevelFilter>, verbose: u8, quiet: bool) -> LevelFilter {
        resolve_level_filter(flag.map(LogLevel), verbose, quiet)
    }

    #[test]
    fn level_names_are_lowercase_and_complete() {
        let names: Vec<_> = LogLevel::value_variants()
            .iter()
            .map(|l| l.to_possible_value().unwrap().get_name().to_owned())
            .collect();
        let expected: Vec<_> = NAMES.iter().map(|(name, _)| *name).collect();
        assert_eq!(names, expected);
    }

    #[test]
    fn level_names_parse_to_their_filter() {
        for (name, filter) in NAMES {
            let level = LogLevel::from_str(name, false).unwrap();
            assert_eq!(LevelFilter::from(level), filter, "{name}");
        }
    }

    #[test]
    fn level_names_are_case_sensitive() {
        assert!(LogLevel::from_str("DEBUG", false).is_err());
        assert!(LogLevel::from_str("Warn", false).is_err());
    }

    #[test]
    fn quiet_logs_only_errors() {
        assert_eq!(resolve(None, 0, true), LevelFilter::Error);
    }

    #[test]
    fn verbose_count_raises_the_level() {
        assert_eq!(resolve(None, 1, false), LevelFilter::Info);
        assert_eq!(resolve(None, 2, false), LevelFilter::Debug);
        assert_eq!(resolve(None, 3, false), LevelFilter::Trace);
    }

    #[test]
    fn verbose_count_saturates_at_trace() {
        assert_eq!(resolve(None, 4, false), LevelFilter::Trace);
        assert_eq!(resolve(None, u8::MAX, false), LevelFilter::Trace);
    }

    #[test]
    fn log_level_flag_is_used_as_is() {
        for (name, filter) in NAMES {
            assert_eq!(resolve(Some(filter), 0, false), filter, "{name}");
        }
    }
}
