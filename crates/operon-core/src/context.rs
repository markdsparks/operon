use crate::{MemoryRecord, Source};

/// Character budgets for deterministic prompt-context compilation.
///
/// Hosts may estimate tokens more accurately for a provider, but every host can
/// apply this portable character-level policy before it sends historical data to
/// a constrained model.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContextBudget {
    pub max_chars: usize,
    pub max_session_chars: usize,
    pub max_memory_chars: usize,
}

impl ContextBudget {
    pub fn from_total(max_chars: usize) -> Self {
        let reserved = max_chars / 3;
        Self {
            max_chars,
            max_session_chars: reserved,
            max_memory_chars: reserved,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompiledContext {
    pub session: String,
    pub memory: String,
    pub sources: String,
    pub omitted_memory_records: usize,
    pub omitted_sources: usize,
}

impl CompiledContext {
    pub fn used_chars(&self) -> usize {
        self.session.chars().count() + self.memory.chars().count() + self.sources.chars().count()
    }
}

pub fn compile_context(
    session: Option<&str>,
    memories: &[MemoryRecord],
    source_records: &[Source],
    budget: ContextBudget,
) -> CompiledContext {
    let session = session.map_or_else(String::new, |text| {
        take_chars(text, budget.max_session_chars.min(budget.max_chars))
    });
    let remaining_after_session = budget.max_chars.saturating_sub(session.chars().count());
    let memory_limit = budget.max_memory_chars.min(remaining_after_session);
    let (memory, included_memories) = format_memory(memories, memory_limit);
    let remaining_for_sources = remaining_after_session.saturating_sub(memory.chars().count());
    let (sources, included_sources) = format_sources(source_records, remaining_for_sources);
    CompiledContext {
        session,
        memory,
        sources,
        omitted_memory_records: memories.len().saturating_sub(included_memories),
        omitted_sources: source_records.len().saturating_sub(included_sources),
    }
}

pub fn format_sources(sources: &[Source], max_chars: usize) -> (String, usize) {
    let mut remaining = max_chars;
    let mut sections = Vec::new();
    let mut included = 0;
    for source in sources {
        let header = format!("[{}] {}\n", source.id, source.path);
        let header_chars = header.chars().count();
        if header_chars >= remaining {
            break;
        }
        let available = remaining - header_chars;
        let text: String = source.text.chars().take(available).collect();
        let consumed = header_chars + text.chars().count() + 2;
        sections.push(format!("{header}{text}"));
        included += 1;
        remaining = remaining.saturating_sub(consumed);
        if remaining == 0 {
            break;
        }
    }
    (sections.join("\n\n"), included)
}

fn format_memory(memories: &[MemoryRecord], max_chars: usize) -> (String, usize) {
    let mut remaining = max_chars;
    let mut sections = Vec::new();
    let mut included = 0;
    for memory in memories {
        let subject = memory
            .subject
            .as_deref()
            .map_or_else(String::new, |subject| format!(" subject={subject}"));
        let kind = format!("{:?}", memory.kind).to_lowercase();
        let authority = format!("{:?}", memory.authority).to_lowercase();
        let sensitivity = format!("{:?}", memory.sensitivity).to_lowercase();
        let header = format!(
            "[M:{}] kind={kind} authority={authority} sensitivity={sensitivity}{subject}\n",
            memory.id
        );
        let header_chars = header.chars().count();
        if header_chars >= remaining {
            break;
        }
        let available = remaining - header_chars;
        let content: String = memory.content.chars().take(available).collect();
        let consumed = header_chars + content.chars().count() + 2;
        sections.push(format!("{header}{content}"));
        included += 1;
        remaining = remaining.saturating_sub(consumed);
        if remaining == 0 {
            break;
        }
    }
    (sections.join("\n\n"), included)
}

fn take_chars(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_owned();
    }
    if max_chars < 2 {
        return text.chars().take(max_chars).collect();
    }
    let mut clipped: String = text.chars().take(max_chars - 1).collect();
    clipped.push('…');
    clipped
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{MemoryAuthority, MemoryKind, MemorySensitivity, MemoryStatus};

    fn memory(content: &str) -> MemoryRecord {
        MemoryRecord {
            id: "M1".into(),
            namespace: "user".into(),
            subject: None,
            kind: MemoryKind::Preference,
            content: content.into(),
            authority: MemoryAuthority::UserConfirmed,
            sensitivity: MemorySensitivity::Private,
            confidence: None,
            source_ids: Vec::new(),
            occurred_at: None,
            observed_at: "2026-07-21T00:00:00Z".into(),
            valid_from: None,
            valid_until: None,
            supersedes: None,
            status: MemoryStatus::Active,
            created_by: "application".into(),
            schema_version: 1,
        }
    }

    #[test]
    fn compiler_respects_total_budget_and_unicode_boundaries() {
        let sources = vec![Source {
            id: "S1".into(),
            path: "policy.md".into(),
            text: "é".repeat(100),
            score: 1.0,
        }];
        let compiled = compile_context(
            Some("historical session"),
            &[memory("Customer prefers concise replies.")],
            &sources,
            ContextBudget {
                max_chars: 160,
                max_session_chars: 20,
                max_memory_chars: 100,
            },
        );

        assert!(compiled.used_chars() <= 160);
        assert!(compiled.sources.is_char_boundary(compiled.sources.len()));
        assert!(compiled.memory.contains("Customer prefers concise"));
    }
}
