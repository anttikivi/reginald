use std::{
    ffi::{OsStr, OsString},
    fmt,
    path::PathBuf,
};

pub const HELP_MESSAGE: &str = "usage: reginald <command> [options]";

#[derive(Default)]
pub struct Args {
    pub command: Option<Command>,
    pub config_file: Option<PathBuf>,
    pub help: Option<bool>,
    pub verbose: Option<bool>,
    pub version: Option<bool>,
    pub working_directory: Option<PathBuf>,
}

impl OptionSet for Args {
    type Option = GlobalOption;

    fn long(name: &str) -> Option<Self::Option> {
        match name {
            "--chdir" => Some(GlobalOption::WorkingDirectory),
            "--config" => Some(GlobalOption::ConfigFile),
            "--help" => Some(GlobalOption::Help),
            "--verbose" => Some(GlobalOption::Verbose),
            "--version" => Some(GlobalOption::Version),
            _ => None,
        }
    }

    fn short(c: u8) -> Option<Self::Option> {
        match c {
            b'C' => Some(GlobalOption::WorkingDirectory),
            b'c' => Some(GlobalOption::ConfigFile),
            b'h' => Some(GlobalOption::Help),
            b'v' => Some(GlobalOption::Verbose),
            b'V' => Some(GlobalOption::Version),
            _ => None,
        }
    }

    fn takes_value(o: Self::Option) -> bool {
        matches!(o, GlobalOption::ConfigFile | GlobalOption::WorkingDirectory)
    }

    fn set(&mut self, o: Self::Option, name: &str, value: Option<OsString>) -> Result<(), Error> {
        match o {
            GlobalOption::ConfigFile => {
                set_option_value(&mut self.config_file, name, path_value(name, value)?)
            }
            GlobalOption::Help => set_option_value(&mut self.help, name, flag_value(name, value)?),
            GlobalOption::Verbose => {
                set_option_value(&mut self.verbose, name, flag_value(name, value)?)
            }
            GlobalOption::Version => {
                set_option_value(&mut self.version, name, flag_value(name, value)?)
            }
            GlobalOption::WorkingDirectory => {
                set_option_value(&mut self.working_directory, name, path_value(name, value)?)
            }
        }
    }
}

#[derive(Debug)]
pub enum Error {
    DuplicateOption(String),
    InvalidBoolean {
        option: String,
        value: OsString,
    },
    #[expect(dead_code)]
    InvalidValue {
        option: String,
        value: OsString,
        reason: String,
    },
    MissingValue(String),
    NotUnicode(OsString),
    UnexpectedArgument(OsString),
    UnknownCommand(OsString),
    UnknownOption(OsString),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DuplicateOption(s) => write!(f, "option \"{s}\" is set twice"),
            Self::InvalidBoolean { option, value } => write!(
                f,
                "option \"{option}\" expects true or false, got \"{}\"",
                value.to_string_lossy()
            ),
            Self::InvalidValue {
                option,
                value,
                reason,
            } => write!(
                f,
                "invalid value \"{}\" for option \"{option}\": {reason}",
                value.to_string_lossy()
            ),
            Self::MissingValue(s) => write!(f, "option \"{s}\" requires a value"),
            Self::NotUnicode(s) => {
                write!(f, "argument is not valid Unicode: {}", s.to_string_lossy())
            }
            Self::UnexpectedArgument(s) => {
                write!(f, "unexpected argument: {}", s.to_string_lossy())
            }
            Self::UnknownCommand(s) => {
                write!(f, "unknown subcommand: {}", s.to_string_lossy())
            }
            Self::UnknownOption(s) => {
                write!(f, "unknown command-line option: {}", s.to_string_lossy())
            }
        }
    }
}

impl std::error::Error for Error {}

pub enum Command {
    Apply(ApplyArgs),
    Plan(PlanArgs),
}

#[derive(Default)]
pub struct ApplyArgs {
    dry_run: Option<bool>,
}

impl OptionSet for ApplyArgs {
    type Option = ApplyOption;

    fn long(name: &str) -> Option<Self::Option> {
        match name {
            "--dry-run" => Some(ApplyOption::DryRun),
            _ => None,
        }
    }

    fn short(c: u8) -> Option<Self::Option> {
        match c {
            b'n' => Some(ApplyOption::DryRun),
            _ => None,
        }
    }

    fn takes_value(_o: Self::Option) -> bool {
        false
    }

    fn set(&mut self, o: Self::Option, name: &str, value: Option<OsString>) -> Result<(), Error> {
        match o {
            ApplyOption::DryRun => {
                set_option_value(&mut self.dry_run, name, flag_value(name, value)?)
            }
        }
    }
}

#[derive(Default)]
pub struct PlanArgs {
    output: Option<PathBuf>,
}

impl OptionSet for PlanArgs {
    type Option = PlanOption;

    fn long(name: &str) -> Option<Self::Option> {
        match name {
            "--output" => Some(PlanOption::Output),
            _ => None,
        }
    }

    fn short(c: u8) -> Option<Self::Option> {
        match c {
            b'o' => Some(PlanOption::Output),
            _ => None,
        }
    }

    fn takes_value(o: Self::Option) -> bool {
        matches!(o, PlanOption::Output)
    }

    fn set(&mut self, o: Self::Option, name: &str, value: Option<OsString>) -> Result<(), Error> {
        match o {
            PlanOption::Output => {
                set_option_value(&mut self.output, name, path_value(name, value)?)
            }
        }
    }
}

/// Trait that stores a set of command-line options.
///
/// Each set lists its options in its own enum, `Option`. The parser looks the
/// option up with `long` or `short`, fetches its value according to
/// `takes_value`, and hands the raw value to `set` for conversion.
trait OptionSet {
    type Option: Copy;

    /// Tries to match the given option name (including the leading hyphens) to
    /// an option.
    fn long(name: &str) -> Option<Self::Option>;

    /// Tries to match the given character to an option.
    fn short(c: u8) -> Option<Self::Option>;

    /// Reports whether the given option consumes a value.
    fn takes_value(o: Self::Option) -> bool;

    /// Converts and stores the value of `o`. `value` is `None` for a flag
    /// given without `=value`, or for an option that takes a value with no
    /// value.
    fn set(&mut self, o: Self::Option, name: &str, value: Option<OsString>) -> Result<(), Error>;
}

#[derive(Clone, Copy)]
enum GlobalOption {
    ConfigFile,
    Help,
    Verbose,
    Version,
    WorkingDirectory,
}

#[derive(Clone, Copy)]
enum ApplyOption {
    DryRun,
}

#[derive(Clone, Copy)]
enum PlanOption {
    Output,
}

/// The result for looking up an option from an option set.
#[derive(PartialEq)]
enum Lookup {
    /// The option isn't found in the set.
    NotFound,
    /// The option is a boolean flag.
    Flag,
    /// The option took a value.
    Value,
}

pub fn parse<I>(argv: I) -> Result<Args, Error>
where
    I: IntoIterator<Item = OsString>,
{
    let mut args = Args::default();
    let mut it = argv.into_iter();

    while let Some(arg) = it.next() {
        // Inspect the argument's encoded bytes so that non-UTF-8 values
        // attached to options, e.g. `-C<path>`, are preserved.
        let bytes = arg.as_encoded_bytes();

        if bytes == b"--" {
            // The command takes no operands for the time being.
            return match it.next() {
                Some(s) => Err(Error::UnexpectedArgument(s)),
                None => break,
            };
        }

        if bytes.starts_with(b"--") {
            let (name, inline_value) = match bytes.iter().position(|&b| b == b'=') {
                Some(i) => {
                    let (n, v) = split_at_ascii(&arg, i);
                    (n, Some(v))
                }
                None => (arg.as_os_str(), None),
            };
            let Some(name) = name.to_str() else {
                return Err(Error::NotUnicode(name.into()));
            };

            let lookup = match try_long(&mut args, name, inline_value, &mut it)? {
                Lookup::NotFound => match &mut args.command {
                    None => Lookup::NotFound,
                    Some(Command::Apply(a)) => try_long(a, name, inline_value, &mut it)?,
                    Some(Command::Plan(a)) => try_long(a, name, inline_value, &mut it)?,
                },
                found => found,
            };

            if lookup == Lookup::NotFound {
                return Err(Error::UnknownOption(name.into()));
            }
        } else if let Some(cluster) = bytes.strip_prefix(b"-").filter(|c| !c.is_empty()) {
            for (i, &c) in cluster.iter().enumerate() {
                let pos = i + 1;
                let lookup = match try_short(&mut args, &arg, pos, &mut it)? {
                    Lookup::NotFound => match &mut args.command {
                        None => Lookup::NotFound,
                        Some(Command::Apply(a)) => try_short(a, &arg, pos, &mut it)?,
                        Some(Command::Plan(a)) => try_short(a, &arg, pos, &mut it)?,
                    },
                    found => found,
                };
                match lookup {
                    Lookup::NotFound => return Err(unknown_short(&arg, c)),
                    Lookup::Flag => {}
                    Lookup::Value => break, // consumes the rest of the argument
                }
            }
        } else {
            if args.command.is_some() || bytes == b"-" {
                return Err(Error::UnexpectedArgument(arg));
            }
            let Some(cmd) = arg.to_str() else {
                return Err(Error::NotUnicode(arg));
            };

            args.command = Some(match cmd {
                "apply" => Command::Apply(ApplyArgs::default()),
                "plan" => Command::Plan(PlanArgs::default()),
                _ => return Err(Error::UnknownCommand(arg)),
            });
        }
    }

    Ok(args)
}

fn split_at_ascii(s: &OsStr, i: usize) -> (&OsStr, &OsStr) {
    let bytes = s.as_encoded_bytes();
    assert!(bytes[i].is_ascii());
    // SAFETY: Splitting immediately before and after an ASCII byte preserves
    // the OS string encoding invariant (including WTF-8 on Windows).
    unsafe {
        (
            OsStr::from_encoded_bytes_unchecked(&bytes[..i]),
            OsStr::from_encoded_bytes_unchecked(&bytes[i + 1..]),
        )
    }
}

/// Parses the long command-line option `name` if it belongs to `target`'s option set.
fn try_long<T: OptionSet>(
    target: &mut T,
    name: &str,
    inline_value: Option<&OsStr>,
    rest: &mut impl Iterator<Item = OsString>,
) -> Result<Lookup, Error> {
    let Some(o) = T::long(name) else {
        return Ok(Lookup::NotFound);
    };

    if T::takes_value(o) {
        let value = inline_value
            .map(OsStr::to_os_string)
            .or_else(|| rest.next());
        target.set(o, name, value)?;
        Ok(Lookup::Value)
    } else {
        target.set(o, name, inline_value.map(OsStr::to_os_string))?;
        Ok(Lookup::Flag)
    }
}

/// Parses the short option at byte `pos` of `arg` if it belongs to `target`'s
/// option set. A value option takes the rest of `arg` as its value, or the next
/// argument from `rest` if nothing follows the option.
fn try_short<T: OptionSet>(
    target: &mut T,
    arg: &OsStr,
    pos: usize,
    rest: &mut impl Iterator<Item = OsString>,
) -> Result<Lookup, Error> {
    let c = arg.as_encoded_bytes()[pos];
    let Some(o) = T::short(c) else {
        return Ok(Lookup::NotFound);
    };
    // Option sets only define ASCII short options, so `c` is ASCII here.
    let name = format!("-{}", c as char);

    if T::takes_value(o) {
        let (_, attached) = split_at_ascii(arg, pos);
        let value = if attached.is_empty() {
            rest.next()
        } else {
            Some(attached.to_os_string())
        };
        target.set(o, &name, value)?;
        Ok(Lookup::Value)
    } else {
        target.set(o, &name, None)?;
        Ok(Lookup::Flag)
    }
}

/// Builds the correct error for an unknown short option `c` found in `arg`.
fn unknown_short(arg: &OsStr, c: u8) -> Error {
    if c.is_ascii() {
        Error::UnknownOption(format!("-{}", c as char).into())
    } else {
        Error::UnknownOption(arg.to_os_string())
    }
}

fn set_option_value<T>(field: &mut Option<T>, name: &str, value: T) -> Result<(), Error> {
    if field.is_some() {
        return Err(Error::DuplicateOption(name.to_string()));
    }

    *field = Some(value);
    Ok(())
}

/// Converts the value of a flag to a boolean. A flag without a value is `true`.
fn flag_value(name: &str, inline_value: Option<OsString>) -> Result<bool, Error> {
    let Some(inline_value) = inline_value else {
        return Ok(true);
    };
    match inline_value.to_str() {
        Some("true" | "1") => Ok(true),
        Some("false" | "0") => Ok(false),
        _ => Err(Error::InvalidBoolean {
            option: name.into(),
            value: inline_value,
        }),
    }
}

/// Validates the value given to an command-line option that takes a path.
fn path_value(name: &str, value: Option<OsString>) -> Result<PathBuf, Error> {
    match value {
        Some(v) if !v.is_empty() => Ok(PathBuf::from(v)),
        _ => Err(Error::MissingValue(name.into())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Parses `argv` given as string slices.
    fn parse_strs(argv: &[&str]) -> Result<Args, Error> {
        parse(argv.iter().map(OsString::from))
    }

    /// Parses `argv` and panics with the error message if parsing fails.
    #[track_caller]
    fn ok(argv: &[&str]) -> Args {
        match parse_strs(argv) {
            Ok(args) => args,
            Err(e) => panic!("parsing {argv:?} failed: {e}"),
        }
    }

    /// Parses `argv` and panics if parsing succeeds.
    #[track_caller]
    fn err(argv: &[&str]) -> Error {
        match parse_strs(argv) {
            Ok(_) => panic!("parsing {argv:?} succeeded, expected an error"),
            Err(e) => e,
        }
    }

    /// Returns the options of the `apply` subcommand, panicking on any other
    /// subcommand.
    #[track_caller]
    fn apply(args: Args) -> ApplyArgs {
        match args.command {
            Some(Command::Apply(a)) => a,
            _ => panic!("expected the apply subcommand"),
        }
    }

    /// Returns the options of the `plan` subcommand, panicking on any other
    /// subcommand.
    #[track_caller]
    fn plan(args: Args) -> PlanArgs {
        match args.command {
            Some(Command::Plan(p)) => p,
            _ => panic!("expected the plan subcommand"),
        }
    }

    fn path(s: &str) -> Option<PathBuf> {
        Some(PathBuf::from(s))
    }

    /// Asserts that parsing `argv` fails with an error that matches `pattern`.
    macro_rules! assert_err {
        ($argv:expr, $pattern:pat $(if $guard:expr)? $(,)?) => {{
            let argv: &[&str] = $argv;
            let e = err(argv);
            assert!(
                matches!(&e, $pattern $(if $guard)?),
                "parsing {argv:?} failed with an unexpected error: {e:?}"
            );
        }};
    }

    #[test]
    fn no_arguments() {
        let a = ok(&[]);
        assert_eq!(a.help, None);
        assert_eq!(a.version, None);
        assert_eq!(a.config_file, None);
        assert_eq!(a.working_directory, None);
        assert!(a.command.is_none());
    }

    mod subcommands {
        use super::*;

        #[test]
        fn apply_without_options() {
            let a = apply(ok(&["apply"]));
            assert_eq!(a.dry_run, None);
        }

        #[test]
        fn plan_without_options() {
            let p = plan(ok(&["plan"]));
            assert_eq!(p.output, None);
        }

        #[test]
        fn unknown_subcommand() {
            assert_err!(&["frobnicate"], Error::UnknownCommand(s) if s == "frobnicate");
        }

        #[test]
        fn names_are_case_sensitive() {
            assert_err!(&["Apply"], Error::UnknownCommand(s) if s == "Apply");
            assert_err!(&["PLAN"], Error::UnknownCommand(s) if s == "PLAN");
        }

        #[test]
        fn names_are_not_abbreviated() {
            assert_err!(&["app"], Error::UnknownCommand(s) if s == "app");
            assert_err!(&["applyx"], Error::UnknownCommand(s) if s == "applyx");
        }

        #[test]
        fn non_ascii_name() {
            assert_err!(&["plän"], Error::UnknownCommand(s) if s == "plän");
        }

        #[test]
        fn empty_argument() {
            assert_err!(&[""], Error::UnknownCommand(s) if s.is_empty());
            assert_err!(&["plan", ""], Error::UnexpectedArgument(s) if s.is_empty());
        }

        #[test]
        fn only_one_subcommand() {
            assert_err!(&["plan", "apply"], Error::UnexpectedArgument(s) if s == "apply");
            assert_err!(&["plan", "plan"], Error::UnexpectedArgument(s) if s == "plan");
        }

        #[test]
        fn no_operands() {
            assert_err!(&["apply", "file"], Error::UnexpectedArgument(s) if s == "file");
        }

        #[test]
        fn lone_dash() {
            assert_err!(&["-"], Error::UnexpectedArgument(s) if s == "-");
            assert_err!(&["plan", "-"], Error::UnexpectedArgument(s) if s == "-");
        }

        #[test]
        fn global_options_on_both_sides() {
            let a = ok(&["-C", "dir", "apply", "--config", "file"]);
            assert_eq!(a.working_directory, path("dir"));
            assert_eq!(a.config_file, path("file"));
            assert_eq!(apply(a).dry_run, None);
        }
    }

    mod double_dash {
        use super::*;

        #[test]
        fn alone() {
            let a = ok(&["--"]);
            assert!(a.command.is_none());
        }

        #[test]
        fn keeps_preceding_arguments() {
            let a = ok(&["-h", "plan", "--"]);
            assert_eq!(a.help, Some(true));
            assert_eq!(plan(a).output, None);
        }

        #[test]
        fn rejects_following_argument() {
            assert_err!(&["--", "plan"], Error::UnexpectedArgument(s) if s == "plan");
        }

        #[test]
        fn stops_option_parsing() {
            assert_err!(&["--", "--help"], Error::UnexpectedArgument(s) if s == "--help");
            assert_err!(&["--", "-h"], Error::UnexpectedArgument(s) if s == "-h");
        }

        #[test]
        fn second_double_dash_is_an_operand() {
            assert_err!(&["--", "--"], Error::UnexpectedArgument(s) if s == "--");
        }
    }

    mod long_flags {
        use super::*;

        #[test]
        fn set_to_true() {
            let a = ok(&["--help", "--version"]);
            assert_eq!(a.help, Some(true));
            assert_eq!(a.version, Some(true));
        }

        #[test]
        fn inline_true() {
            for value in ["true", "1"] {
                let arg = format!("--help={value}");
                assert_eq!(ok(&[&arg]).help, Some(true), "{arg}");
            }
        }

        #[test]
        fn inline_false() {
            for value in ["false", "0"] {
                let arg = format!("--version={value}");
                assert_eq!(ok(&[&arg]).version, Some(false), "{arg}");
            }
        }

        #[test]
        fn invalid_inline_value() {
            for value in ["yes", "no", "TRUE", "False", "2", "", " true", "true "] {
                let arg = format!("--help={value}");
                assert_err!(
                    &[&arg],
                    Error::InvalidBoolean { option, value: v } if option == "--help" && v == value,
                );
            }
        }

        #[test]
        fn does_not_take_next_argument() {
            let a = ok(&["--help", "plan"]);
            assert_eq!(a.help, Some(true));
            assert_eq!(plan(a).output, None);

            let a = ok(&["--version", "--help"]);
            assert_eq!(a.version, Some(true));
            assert_eq!(a.help, Some(true));
        }

        #[test]
        fn duplicate() {
            assert_err!(&["--help", "--help"], Error::DuplicateOption(s) if s == "--help");
            assert_err!(&["--help=false", "--help"], Error::DuplicateOption(s) if s == "--help");
        }

        #[test]
        fn duplicate_across_spellings() {
            assert_err!(&["-h", "--help"], Error::DuplicateOption(s) if s == "--help");
            assert_err!(&["--help", "-h"], Error::DuplicateOption(s) if s == "-h");
        }

        #[test]
        fn after_subcommand() {
            let a = ok(&["apply", "--help"]);
            assert_eq!(a.help, Some(true));
            assert_eq!(apply(a).dry_run, None);
        }
    }

    mod long_names {
        use super::*;

        #[test]
        fn unknown() {
            assert_err!(&["--nope"], Error::UnknownOption(s) if s == "--nope");
        }

        #[test]
        fn unknown_reports_name_without_value() {
            assert_err!(&["--nope=1"], Error::UnknownOption(s) if s == "--nope");
        }

        #[test]
        fn case_sensitive() {
            assert_err!(&["--HELP"], Error::UnknownOption(s) if s == "--HELP");
        }

        #[test]
        fn not_abbreviated() {
            assert_err!(&["--hel"], Error::UnknownOption(s) if s == "--hel");
            assert_err!(&["--ch"], Error::UnknownOption(s) if s == "--ch");
        }

        #[test]
        fn three_dashes() {
            assert_err!(&["---help"], Error::UnknownOption(s) if s == "---help");
        }

        #[test]
        fn empty_name_with_value() {
            assert_err!(&["--=x"], Error::UnknownOption(s) if s == "--");
        }

        #[test]
        fn single_dash_is_a_short_cluster() {
            assert_err!(&["-help"], Error::UnknownOption(s) if s == "-e");
        }
    }

    mod long_values {
        use super::*;

        #[test]
        fn separate_value() {
            let a = ok(&["--chdir", "dir", "--config", "file"]);
            assert_eq!(a.working_directory, path("dir"));
            assert_eq!(a.config_file, path("file"));
        }

        #[test]
        fn inline_value() {
            let a = ok(&["--chdir=dir", "--config=file"]);
            assert_eq!(a.working_directory, path("dir"));
            assert_eq!(a.config_file, path("file"));
        }

        #[test]
        fn value_split_at_first_equals_sign() {
            assert_eq!(ok(&["--chdir=a=b"]).working_directory, path("a=b"));
            assert_eq!(ok(&["--chdir=="]).working_directory, path("="));
        }

        #[test]
        fn separate_value_may_contain_equals_sign() {
            assert_eq!(ok(&["--config", "a=b"]).config_file, path("a=b"));
        }

        #[test]
        fn spaces_and_non_ascii() {
            let a = ok(&["--chdir", "my dir/äö €"]);
            assert_eq!(a.working_directory, path("my dir/äö €"));
        }

        #[test]
        fn inline_value_that_looks_like_an_option() {
            let a = ok(&["--chdir=-h"]);
            assert_eq!(a.working_directory, path("-h"));
            assert_eq!(a.help, None);
        }

        #[test]
        fn next_argument_taken_verbatim() {
            let a = ok(&["--chdir", "--help"]);
            assert_eq!(a.working_directory, path("--help"));
            assert_eq!(a.help, None);

            assert_eq!(ok(&["--chdir", "-"]).working_directory, path("-"));
            assert_eq!(ok(&["--chdir", "--"]).working_directory, path("--"));
            assert_eq!(ok(&["--config", "plan"]).config_file, path("plan"));
        }

        #[test]
        fn missing_at_end() {
            assert_err!(&["--chdir"], Error::MissingValue(s) if s == "--chdir");
            assert_err!(&["--config"], Error::MissingValue(s) if s == "--config");
            assert_err!(&["apply", "--chdir"], Error::MissingValue(s) if s == "--chdir");
        }

        #[test]
        fn empty_inline() {
            assert_err!(&["--chdir="], Error::MissingValue(s) if s == "--chdir");
        }

        #[test]
        fn empty_separate() {
            assert_err!(&["--config", ""], Error::MissingValue(s) if s == "--config");
        }

        #[test]
        fn duplicate() {
            assert_err!(
                &["--chdir", "a", "--chdir", "b"],
                Error::DuplicateOption(s) if s == "--chdir",
            );
            assert_err!(&["--config=a", "--config=b"], Error::DuplicateOption(s) if s == "--config");
        }

        #[test]
        fn duplicate_across_spellings() {
            assert_err!(&["-C", "a", "--chdir=b"], Error::DuplicateOption(s) if s == "--chdir");
            assert_err!(&["--config=a", "-cb"], Error::DuplicateOption(s) if s == "-c");
        }

        #[test]
        fn after_subcommand() {
            let a = ok(&["plan", "--chdir", "dir"]);
            assert_eq!(a.working_directory, path("dir"));
            assert_eq!(plan(a).output, None);
        }
    }

    mod short_flags {
        use super::*;

        #[test]
        fn single() {
            assert_eq!(ok(&["-h"]).help, Some(true));
            assert_eq!(ok(&["-V"]).version, Some(true));
        }

        #[test]
        fn cluster() {
            for arg in ["-hV", "-Vh"] {
                let a = ok(&[arg]);
                assert_eq!(a.help, Some(true), "{arg}");
                assert_eq!(a.version, Some(true), "{arg}");
            }
        }

        #[test]
        fn separate() {
            let a = ok(&["-h", "-V"]);
            assert_eq!(a.help, Some(true));
            assert_eq!(a.version, Some(true));
        }

        #[test]
        fn duplicate() {
            assert_err!(&["-hh"], Error::DuplicateOption(s) if s == "-h");
            assert_err!(&["-h", "-h"], Error::DuplicateOption(s) if s == "-h");
            assert_err!(&["-hVh"], Error::DuplicateOption(s) if s == "-h");
        }

        #[test]
        fn does_not_take_next_argument() {
            let a = ok(&["-h", "apply"]);
            assert_eq!(a.help, Some(true));
            assert_eq!(apply(a).dry_run, None);
        }

        #[test]
        fn never_take_a_value() {
            assert_err!(&["-h=1"], Error::UnknownOption(s) if s == "-=");
        }

        #[test]
        fn unknown() {
            assert_err!(&["-x"], Error::UnknownOption(s) if s == "-x");
            assert_err!(&["-1"], Error::UnknownOption(s) if s == "-1");
        }

        #[test]
        fn unknown_in_cluster() {
            assert_err!(&["-hx"], Error::UnknownOption(s) if s == "-x");
            assert_err!(&["-xh"], Error::UnknownOption(s) if s == "-x");
        }

        #[test]
        fn case_sensitive() {
            assert_err!(&["-H"], Error::UnknownOption(s) if s == "-H");
            assert_err!(&["-v"], Error::UnknownOption(s) if s == "-v");
        }

        #[test]
        fn non_ascii_reports_whole_argument() {
            assert_err!(&["-é"], Error::UnknownOption(s) if s == "-é");
            assert_err!(&["-hé"], Error::UnknownOption(s) if s == "-hé");
            assert_err!(&["-€"], Error::UnknownOption(s) if s == "-€");
        }

        #[test]
        fn after_subcommand() {
            let a = ok(&["plan", "-hV"]);
            assert_eq!(a.help, Some(true));
            assert_eq!(a.version, Some(true));
            assert_eq!(plan(a).output, None);
        }
    }

    mod short_values {
        use super::*;

        #[test]
        fn separate_value() {
            let a = ok(&["-C", "dir", "-c", "file"]);
            assert_eq!(a.working_directory, path("dir"));
            assert_eq!(a.config_file, path("file"));
        }

        #[test]
        fn attached_value() {
            let a = ok(&["-Cdir", "-cfile"]);
            assert_eq!(a.working_directory, path("dir"));
            assert_eq!(a.config_file, path("file"));
        }

        #[test]
        fn after_flags_in_cluster() {
            let a = ok(&["-hCdir"]);
            assert_eq!(a.help, Some(true));
            assert_eq!(a.working_directory, path("dir"));
        }

        #[test]
        fn at_end_of_cluster_takes_next_argument() {
            let a = ok(&["-hC", "dir"]);
            assert_eq!(a.help, Some(true));
            assert_eq!(a.working_directory, path("dir"));
        }

        #[test]
        fn consumes_rest_of_cluster() {
            let a = ok(&["-Ch"]);
            assert_eq!(a.working_directory, path("h"));
            assert_eq!(a.help, None);

            let a = ok(&["-Ccfile"]);
            assert_eq!(a.working_directory, path("cfile"));
            assert_eq!(a.config_file, None);
        }

        #[test]
        fn equals_sign_is_part_of_attached_value() {
            assert_eq!(ok(&["-C=dir"]).working_directory, path("=dir"));
        }

        #[test]
        fn non_ascii_attached_value() {
            assert_eq!(ok(&["-Cé"]).working_directory, path("é"));
            assert_eq!(ok(&["-Cdir/äö"]).working_directory, path("dir/äö"));
        }

        #[test]
        fn next_argument_taken_verbatim() {
            let a = ok(&["-C", "-h"]);
            assert_eq!(a.working_directory, path("-h"));
            assert_eq!(a.help, None);
        }

        #[test]
        fn missing_at_end() {
            assert_err!(&["-C"], Error::MissingValue(s) if s == "-C");
            assert_err!(&["-hc"], Error::MissingValue(s) if s == "-c");
        }

        #[test]
        fn empty_separate() {
            assert_err!(&["-C", ""], Error::MissingValue(s) if s == "-C");
        }

        #[test]
        fn duplicate() {
            assert_err!(&["-Ca", "-Cb"], Error::DuplicateOption(s) if s == "-C");
            assert_err!(&["-ca", "--config", "b"], Error::DuplicateOption(s) if s == "--config");
        }

        #[test]
        fn after_subcommand() {
            let a = ok(&["apply", "-Cdir"]);
            assert_eq!(a.working_directory, path("dir"));
            assert_eq!(apply(a).dry_run, None);
        }
    }

    mod apply_options {
        use super::*;

        #[test]
        fn dry_run() {
            for arg in ["--dry-run", "-n", "--dry-run=true", "--dry-run=1"] {
                assert_eq!(apply(ok(&["apply", arg])).dry_run, Some(true), "{arg}");
            }
            for arg in ["--dry-run=false", "--dry-run=0"] {
                assert_eq!(apply(ok(&["apply", arg])).dry_run, Some(false), "{arg}");
            }
        }

        #[test]
        fn invalid_dry_run_value() {
            assert_err!(
                &["apply", "--dry-run=maybe"],
                Error::InvalidBoolean { option, value } if option == "--dry-run" && value == "maybe",
            );
        }

        #[test]
        fn dry_run_does_not_take_next_argument() {
            assert_err!(&["apply", "-n", "x"], Error::UnexpectedArgument(s) if s == "x");
        }

        #[test]
        fn duplicate() {
            assert_err!(&["apply", "-nn"], Error::DuplicateOption(s) if s == "-n");
            assert_err!(&["apply", "-n", "--dry-run"], Error::DuplicateOption(s) if s == "--dry-run");
        }

        #[test]
        fn mixed_with_global_options_in_cluster() {
            for arg in ["-hn", "-nh"] {
                let a = ok(&["apply", arg]);
                assert_eq!(a.help, Some(true), "{arg}");
                assert_eq!(apply(a).dry_run, Some(true), "{arg}");
            }

            let a = ok(&["apply", "-nCdir"]);
            assert_eq!(a.working_directory, path("dir"));
            assert_eq!(apply(a).dry_run, Some(true));
        }

        #[test]
        fn rejected_before_subcommand() {
            assert_err!(&["--dry-run", "apply"], Error::UnknownOption(s) if s == "--dry-run");
            assert_err!(&["-n", "apply"], Error::UnknownOption(s) if s == "-n");
        }

        #[test]
        fn rejected_for_plan() {
            assert_err!(&["plan", "--dry-run"], Error::UnknownOption(s) if s == "--dry-run");
            assert_err!(&["plan", "-n"], Error::UnknownOption(s) if s == "-n");
        }
    }

    mod plan_options {
        use super::*;

        #[test]
        fn output_separate_value() {
            assert_eq!(plan(ok(&["plan", "--output", "out"])).output, path("out"));
            assert_eq!(plan(ok(&["plan", "-o", "out"])).output, path("out"));
        }

        #[test]
        fn output_inline_value() {
            assert_eq!(plan(ok(&["plan", "--output=out"])).output, path("out"));
        }

        #[test]
        fn output_attached_value() {
            assert_eq!(plan(ok(&["plan", "-oout"])).output, path("out"));
        }

        #[test]
        fn output_after_global_flag_in_cluster() {
            let a = ok(&["plan", "-hoout"]);
            assert_eq!(a.help, Some(true));
            assert_eq!(plan(a).output, path("out"));
        }

        #[test]
        fn output_next_argument_taken_verbatim() {
            let a = ok(&["plan", "-o", "-h"]);
            assert_eq!(a.help, None);
            assert_eq!(plan(a).output, path("-h"));
        }

        #[test]
        fn output_missing() {
            assert_err!(&["plan", "--output"], Error::MissingValue(s) if s == "--output");
            assert_err!(&["plan", "-o"], Error::MissingValue(s) if s == "-o");
            assert_err!(&["plan", "--output="], Error::MissingValue(s) if s == "--output");
        }

        #[test]
        fn duplicate() {
            assert_err!(
                &["plan", "-o", "a", "--output", "b"],
                Error::DuplicateOption(s) if s == "--output",
            );
        }

        #[test]
        fn rejected_before_subcommand() {
            assert_err!(&["--output", "out", "plan"], Error::UnknownOption(s) if s == "--output");
            assert_err!(&["-o", "out", "plan"], Error::UnknownOption(s) if s == "-o");
        }

        #[test]
        fn rejected_for_apply() {
            assert_err!(&["apply", "--output", "out"], Error::UnknownOption(s) if s == "--output");
            assert_err!(&["apply", "-oout"], Error::UnknownOption(s) if s == "-o");
        }
    }

    /// Tests for arguments that aren't valid Unicode, which can only be built
    /// with platform-specific APIs.
    #[cfg(any(unix, windows))]
    mod not_unicode {
        use super::*;

        /// Returns a string that isn't valid Unicode: a lone `0xFF` byte on
        /// Unix and an unpaired surrogate on Windows.
        fn invalid() -> OsString {
            #[cfg(unix)]
            {
                use std::os::unix::ffi::OsStringExt;
                OsString::from_vec(vec![0xFF])
            }
            #[cfg(windows)]
            {
                use std::os::windows::ffi::OsStringExt;
                OsString::from_wide(&[0xD800])
            }
        }

        /// Joins the parts into one argument.
        fn join(parts: &[&OsStr]) -> OsString {
            let mut s = OsString::new();
            for part in parts {
                s.push(part);
            }
            s
        }

        /// Returns a path value that isn't valid Unicode.
        fn invalid_path() -> OsString {
            join(&["dir/".as_ref(), &invalid()])
        }

        #[track_caller]
        fn ok_os(argv: Vec<OsString>) -> Args {
            match parse(argv) {
                Ok(args) => args,
                Err(e) => panic!("parsing failed: {e}"),
            }
        }

        #[track_caller]
        fn err_os(argv: Vec<OsString>) -> Error {
            match parse(argv) {
                Ok(_) => panic!("parsing succeeded, expected an error"),
                Err(e) => e,
            }
        }

        #[test]
        fn helper_is_not_unicode() {
            assert!(invalid().to_str().is_none());
            assert!(invalid_path().to_str().is_none());
        }

        #[test]
        fn long_separate_value_preserved() {
            let a = ok_os(vec!["--chdir".into(), invalid_path()]);
            assert_eq!(a.working_directory, Some(PathBuf::from(invalid_path())));
        }

        #[test]
        fn long_inline_value_preserved() {
            let a = ok_os(vec![join(&["--config=".as_ref(), &invalid_path()])]);
            assert_eq!(a.config_file, Some(PathBuf::from(invalid_path())));
        }

        #[test]
        fn short_attached_value_preserved() {
            let a = ok_os(vec![join(&["-C".as_ref(), &invalid_path()])]);
            assert_eq!(a.working_directory, Some(PathBuf::from(invalid_path())));

            let a = ok_os(vec![join(&["-hc".as_ref(), &invalid()])]);
            assert_eq!(a.help, Some(true));
            assert_eq!(a.config_file, Some(PathBuf::from(invalid())));
        }

        #[test]
        fn short_separate_value_preserved() {
            let a = ok_os(vec!["-C".into(), invalid_path()]);
            assert_eq!(a.working_directory, Some(PathBuf::from(invalid_path())));
        }

        #[test]
        fn subcommand_value_preserved() {
            let a = ok_os(vec!["plan".into(), join(&["-o".as_ref(), &invalid_path()])]);
            assert_eq!(plan(a).output, Some(PathBuf::from(invalid_path())));
        }

        #[test]
        fn long_name() {
            let arg = join(&["--".as_ref(), &invalid()]);
            assert!(matches!(err_os(vec![arg.clone()]), Error::NotUnicode(s) if s == arg));
        }

        #[test]
        fn long_name_reported_without_value() {
            let name = join(&["--".as_ref(), &invalid()]);
            let arg = join(&[&name, "=x".as_ref()]);
            assert!(matches!(err_os(vec![arg]), Error::NotUnicode(s) if s == name));
        }

        #[test]
        fn flag_value() {
            let arg = join(&["--help=".as_ref(), &invalid()]);
            assert!(matches!(
                err_os(vec![arg]),
                Error::InvalidBoolean { option, value } if option == "--help" && value == invalid(),
            ));
        }

        #[test]
        fn short_cluster_reports_whole_argument() {
            let arg = join(&["-h".as_ref(), &invalid()]);
            assert!(matches!(err_os(vec![arg.clone()]), Error::UnknownOption(s) if s == arg));
        }

        #[test]
        fn subcommand() {
            assert!(matches!(err_os(vec![invalid()]), Error::NotUnicode(s) if s == invalid()));
        }

        #[test]
        fn operand_after_subcommand() {
            assert!(matches!(
                err_os(vec!["plan".into(), invalid()]),
                Error::UnexpectedArgument(s) if s == invalid(),
            ));
        }
    }

    mod error_messages {
        use super::*;

        #[test]
        fn duplicate_option() {
            assert_eq!(
                err(&["-h", "-h"]).to_string(),
                r#"option "-h" is set twice"#
            );
        }

        #[test]
        fn invalid_boolean() {
            assert_eq!(
                err(&["--help=yes"]).to_string(),
                r#"option "--help" expects true or false, got "yes""#
            );
        }

        #[test]
        fn missing_value() {
            assert_eq!(
                err(&["--chdir"]).to_string(),
                r#"option "--chdir" requires a value"#
            );
        }

        #[test]
        fn not_unicode() {
            assert_eq!(
                Error::NotUnicode("x".into()).to_string(),
                "argument is not valid Unicode: x"
            );
        }

        #[test]
        fn unexpected_argument() {
            assert_eq!(
                err(&["plan", "apply"]).to_string(),
                "unexpected argument: apply"
            );
        }

        #[test]
        fn unknown_command() {
            assert_eq!(
                err(&["frobnicate"]).to_string(),
                "unknown subcommand: frobnicate"
            );
        }

        #[test]
        fn unknown_option() {
            assert_eq!(
                err(&["--nope"]).to_string(),
                "unknown command-line option: --nope"
            );
            assert_eq!(err(&["-é"]).to_string(), "unknown command-line option: -é");
        }
    }

    mod split_at_ascii {
        use super::*;

        fn split(s: &str, i: usize) -> (&OsStr, &OsStr) {
            super::split_at_ascii(OsStr::new(s), i)
        }

        #[test]
        fn removes_the_byte() {
            assert_eq!(split("--a=b", 3), ("--a".as_ref(), "b".as_ref()));
        }

        #[test]
        fn at_start() {
            assert_eq!(split("=b", 0), ("".as_ref(), "b".as_ref()));
        }

        #[test]
        fn at_end() {
            assert_eq!(split("a=", 1), ("a".as_ref(), "".as_ref()));
        }

        #[test]
        fn keeps_non_ascii_on_both_sides() {
            assert_eq!(split("ä=ö", 2), ("ä".as_ref(), "ö".as_ref()));
        }

        #[test]
        #[should_panic]
        fn panics_on_non_ascii_byte() {
            split("ä", 0);
        }
    }
}
