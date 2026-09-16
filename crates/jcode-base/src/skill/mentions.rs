//! Inline `/skill` mentions inside a user message.
//!
//! The client-selected `active_skill` names the leading skill for a turn. In
//! addition, the daemon scans the message text for `/name` tokens at a word
//! start whose `name` is an installed skill, and injects each SKILL.md body
//! into that turn's system reminder (see `PHONE-WIRE.md`, "The daemon
//! resolves every /skill in a message").

use super::SkillRegistry;

/// Maximum characters injected for a single mentioned skill.
pub const MAX_CHARS_PER_SKILL: usize = 12_000;
/// Maximum characters injected for all mentioned skills of one turn.
pub const MAX_CHARS_TOTAL: usize = 36_000;

fn is_name_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || c == '-'
}

/// Candidate `/name` tokens: `/` at the start of the text or right after
/// whitespace, followed by `[A-Za-z0-9_-]+`. Not deduplicated, not checked
/// against the registry.
pub fn candidate_mentions(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut prev_is_boundary = true;
    let mut chars = text.char_indices().peekable();
    while let Some((idx, c)) = chars.next() {
        if c == '/' && prev_is_boundary {
            let start = idx + 1;
            let mut end = start;
            while let Some(&(next_idx, next_c)) = chars.peek() {
                if is_name_char(next_c) {
                    end = next_idx + next_c.len_utf8();
                    chars.next();
                } else {
                    break;
                }
            }
            if end > start {
                // A name directly followed by `/` (e.g. `/usr/bin`) is a path.
                let followed_by_slash = chars.peek().is_some_and(|&(_, next)| next == '/');
                if !followed_by_slash {
                    out.push(&text[start..end]);
                }
            }
            prev_is_boundary = false;
            continue;
        }
        prev_is_boundary = c.is_whitespace();
    }
    out
}

/// Installed skills mentioned inline in `text`, excluding `active_skill`,
/// deduplicated, in order of first appearance.
pub fn mentioned_skills(
    text: &str,
    skills: &SkillRegistry,
    active_skill: Option<&str>,
) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for name in candidate_mentions(text) {
        if Some(name) == active_skill {
            continue;
        }
        if !skills.contains(name) {
            continue;
        }
        if out.iter().any(|seen| seen == name) {
            continue;
        }
        out.push(name.to_string());
    }
    out
}

/// One rendered section per mentioned skill, clamped per skill and in total.
/// A clamped section ends with `[clamped, full text: <path>]`.
pub fn render_mentioned_sections(names: &[String], skills: &SkillRegistry) -> Option<String> {
    let mut sections = Vec::new();
    let mut remaining_total = MAX_CHARS_TOTAL;
    for name in names {
        let Some(skill) = skills.get(name) else {
            continue;
        };
        // Too little room left for anything beyond the clamp marker itself.
        if remaining_total < 256 {
            break;
        }
        let budget = MAX_CHARS_PER_SKILL.min(remaining_total);
        let section = render_section(skill, budget);
        remaining_total = remaining_total.saturating_sub(section.chars().count());
        sections.push(section);
    }
    if sections.is_empty() {
        None
    } else {
        Some(sections.join("\n\n"))
    }
}

fn render_section(skill: &super::Skill, budget: usize) -> String {
    let header = format!("## Skill: /{}\n\n", skill.name);
    let body = skill.get_prompt();
    if header.chars().count() + body.chars().count() <= budget {
        return format!("{header}{body}");
    }
    let marker = format!("\n[clamped, full text: {}]", skill.path.display());
    let allowed = budget
        .saturating_sub(header.chars().count())
        .saturating_sub(marker.chars().count());
    let truncated: String = body.chars().take(allowed).collect();
    format!("{header}{truncated}{marker}")
}

/// Fold the rendered skill sections into a turn's system reminder.
pub fn merge_into_system_reminder(
    system_reminder: Option<String>,
    sections: Option<String>,
) -> Option<String> {
    match (system_reminder, sections) {
        (reminder, None) => reminder,
        (None, Some(sections)) => Some(sections),
        (Some(reminder), Some(sections)) => {
            let reminder = reminder.trim_end();
            if reminder.is_empty() {
                Some(sections)
            } else {
                Some(format!("{reminder}\n\n{sections}"))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn registry(names: &[&str]) -> SkillRegistry {
        let mut registry = SkillRegistry::default();
        for name in names {
            registry.insert_for_test(super::super::Skill {
                name: name.to_string(),
                description: format!("{name} description"),
                allowed_tools: None,
                content: format!("{name} body"),
                path: PathBuf::from(format!("/skills/{name}/SKILL.md")),
                search_text: String::new(),
            });
        }
        registry
    }

    #[test]
    fn candidates_only_at_word_start() {
        assert_eq!(candidate_mentions("/foo bar"), vec!["foo"]);
        assert_eq!(
            candidate_mentions("x /foo\t/bar\n/baz"),
            vec!["foo", "bar", "baz"]
        );
        assert!(candidate_mentions("src/foo").is_empty());
        assert!(candidate_mentions("a/b").is_empty());
        assert!(candidate_mentions("/usr/bin").is_empty());
        assert!(candidate_mentions("/").is_empty());
        assert!(candidate_mentions("/ foo").is_empty());
        assert_eq!(candidate_mentions("/a-b_1, next"), vec!["a-b_1"]);
        assert_eq!(candidate_mentions("(/foo)"), Vec::<&str>::new());
    }

    #[test]
    fn mentioned_skills_filters_unknown_active_and_duplicates() {
        let skills = registry(&["review", "ship"]);
        assert_eq!(
            mentioned_skills("/ship then /review then /ship /nope", &skills, None),
            vec!["ship", "review"]
        );
        assert_eq!(
            mentioned_skills("/ship then /review", &skills, Some("ship")),
            vec!["review"]
        );
        assert!(mentioned_skills("path src/ship /usr/review", &skills, None).is_empty());
    }

    #[test]
    fn short_bodies_are_not_clamped() {
        let skills = registry(&["review"]);
        let out = render_mentioned_sections(&["review".to_string()], &skills).unwrap();
        assert!(out.starts_with("## Skill: /review"));
        assert!(out.contains("review body"));
        assert!(!out.contains("[clamped"));
    }

    #[test]
    fn long_bodies_are_clamped_per_skill_and_total() {
        let mut skills = SkillRegistry::default();
        for name in ["a", "b", "c", "d"] {
            skills.insert_for_test(super::super::Skill {
                name: name.to_string(),
                description: String::new(),
                allowed_tools: None,
                content: "x".repeat(MAX_CHARS_PER_SKILL + 500),
                path: PathBuf::from(format!("/skills/{name}/SKILL.md")),
                search_text: String::new(),
            });
        }
        let names: Vec<String> = ["a", "b", "c", "d"].iter().map(|s| s.to_string()).collect();
        let out = render_mentioned_sections(&names, &skills).unwrap();
        let sections: Vec<&str> = out.split("\n\n## Skill: /").collect();
        // 3 x 12 000 fills the 36 000 total budget; the fourth skill is dropped.
        assert_eq!(
            sections.len(),
            3,
            "total clamp drops the fourth: {}",
            out.len()
        );
        for section in &sections {
            assert!(section.chars().count() <= MAX_CHARS_PER_SKILL + 2);
            assert!(section.contains("[clamped, full text: /skills/"));
        }
        assert!(out.chars().count() <= MAX_CHARS_TOTAL + 4);
        assert!(out.contains("[clamped, full text: /skills/a/SKILL.md]"));
        assert!(!out.contains("/skills/d/SKILL.md"));
    }

    #[test]
    fn merge_appends_after_existing_reminder() {
        assert_eq!(merge_into_system_reminder(None, None), None);
        assert_eq!(
            merge_into_system_reminder(Some("r".into()), None),
            Some("r".into())
        );
        assert_eq!(
            merge_into_system_reminder(None, Some("s".into())),
            Some("s".into())
        );
        assert_eq!(
            merge_into_system_reminder(Some("r\n".into()), Some("s".into())),
            Some("r\n\ns".into())
        );
    }
}
