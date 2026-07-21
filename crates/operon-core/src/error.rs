use std::error::Error;
use std::fmt::{Display, Formatter};

/// Failures crossing Operon's portable public boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OperonError {
    InvalidPolicy(String),
    InvalidRequest(String),
    PolicyViolation(String),
    Provider(String),
    Grounding(String),
    Memory(String),
    InvalidModelOutput(String),
    Validation(Vec<String>),
}

impl Display for OperonError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidPolicy(message) => write!(formatter, "invalid policy: {message}"),
            Self::InvalidRequest(message) => write!(formatter, "invalid request: {message}"),
            Self::PolicyViolation(message) => write!(formatter, "policy violation: {message}"),
            Self::Provider(message) => write!(formatter, "provider failed: {message}"),
            Self::Grounding(message) => write!(formatter, "grounding failed: {message}"),
            Self::Memory(message) => write!(formatter, "memory failed: {message}"),
            Self::InvalidModelOutput(message) => {
                write!(formatter, "invalid model output: {message}")
            }
            Self::Validation(errors) => {
                write!(formatter, "validation failed: {}", errors.join("; "))
            }
        }
    }
}

impl Error for OperonError {}

pub type OperonResult<T> = Result<T, OperonError>;
