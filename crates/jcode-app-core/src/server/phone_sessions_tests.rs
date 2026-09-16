use super::*;

#[test]
fn phase_ranking_prompt_beats_error_beats_running_beats_idle() {
    assert_eq!(rank_phase(PhaseInputs::default()), Phase::Idle);
    assert_eq!(
        rank_phase(PhaseInputs {
            turn_live: true,
            ..Default::default()
        }),
        Phase::Running
    );
    assert_eq!(
        rank_phase(PhaseInputs {
            last_turn_errored: true,
            ..Default::default()
        }),
        Phase::Failed
    );
    // A later live turn supersedes a stale error.
    assert_eq!(
        rank_phase(PhaseInputs {
            last_turn_errored: true,
            turn_live: true,
            ..Default::default()
        }),
        Phase::Running
    );
    assert_eq!(
        rank_phase(PhaseInputs {
            has_pending_prompt: true,
            last_turn_errored: true,
            turn_live: true,
        }),
        Phase::NeedsYou
    );
    assert_eq!(Phase::NeedsYou.as_str(), "needs_you");
}

#[test]
fn preview_priority_prompt_streaming_assistant_user() {
    let all = PreviewCandidates {
        prompt: Some("Which DB?".into()),
        streaming: Some("partial".into()),
        assistant: Some("done".into()),
        user: Some("hi".into()),
    };
    assert_eq!(pick_preview(all.clone()).unwrap().kind, "prompt");
    let no_prompt = PreviewCandidates {
        prompt: None,
        ..all.clone()
    };
    assert_eq!(pick_preview(no_prompt.clone()).unwrap().kind, "streaming");
    let no_stream = PreviewCandidates {
        streaming: None,
        ..no_prompt
    };
    assert_eq!(pick_preview(no_stream.clone()).unwrap().kind, "assistant");
    let only_user = PreviewCandidates {
        assistant: Some("   ".into()),
        ..no_stream
    };
    let preview = pick_preview(only_user).unwrap();
    assert_eq!(preview.kind, "user");
    assert_eq!(preview.text, "hi");
    assert!(pick_preview(PreviewCandidates::default()).is_none());
}

#[test]
fn preview_is_trimmed_to_240_chars_and_strips_reminders() {
    let long = "x".repeat(500);
    let preview = pick_preview(PreviewCandidates {
        assistant: Some(long),
        ..Default::default()
    })
    .unwrap();
    assert_eq!(preview.text.chars().count(), PREVIEW_MAX_CHARS + 1);
    assert!(preview.text.ends_with('…'));

    let stripped = strip_system_reminders(
        "hello <system-reminder>secret</system-reminder> world<system-reminder>unterminated",
    );
    assert_eq!(stripped, "hello  world");
}

#[test]
fn empty_live_session_is_skipped_unless_a_named_client_holds_it() {
    let anonymous = LiveInfo::default();
    let named = LiveInfo {
        has_named_client: true,
        ..Default::default()
    };
    assert!(is_connection_artefact(false, false, &anonymous));
    assert!(!is_connection_artefact(false, false, &named));
    assert!(!is_connection_artefact(true, false, &anonymous));
    assert!(!is_connection_artefact(false, true, &anonymous));

    let mut conns = HashMap::new();
    let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
    conns.insert(
        "c1".to_string(),
        ClientConnectionInfo {
            client_id: "c1".to_string(),
            session_id: "s".to_string(),
            client_instance_id: Some("jed-tab".to_string()),
            debug_client_id: None,
            connected_at: Instant::now(),
            last_seen: Instant::now(),
            is_processing: false,
            current_tool_name: None,
            terminal_env: Vec::new(),
            disconnect_tx: tx,
        },
    );
    assert!(live_info_by_session(&conns)["s"].has_named_client);
}

fn row(id: &str, dir: Option<&str>, updated: &str) -> SessionRow {
    SessionRow {
        id: id.to_string(),
        short_name: None,
        title: None,
        working_dir: dir.map(str::to_string),
        created_at: updated.to_string(),
        updated_at: updated.to_string(),
        last_active_at: None,
        model: None,
        provider: None,
        phase: "idle".to_string(),
        reason: None,
        current_tool: None,
        turn_started_at: None,
        queued: 0,
        pending_prompt: None,
        preview: None,
        client_count: 0,
        is_live: false,
        parent_id: None,
        swarm_role: None,
    }
}

#[test]
fn recent_projects_pins_first_and_dedupes() {
    let rows = vec![
        row("a", Some("/p/one"), "2026-01-03T00:00:00Z"),
        row("b", Some("/p/two"), "2026-01-02T00:00:00Z"),
        row("c", Some("/p/one"), "2026-01-01T00:00:00Z"),
        row("d", None, "2026-01-01T00:00:00Z"),
    ];
    let pins = vec![
        "/p/two".to_string(),
        "/p/pinned".to_string(),
        "/p/two".to_string(),
    ];
    let projects = recent_projects(&pins, &rows);
    let paths: Vec<&str> = projects.iter().map(|p| p.path.as_str()).collect();
    assert_eq!(paths, vec!["/p/two", "/p/pinned", "/p/one"]);
    assert_eq!(projects[0].session_count, 1);
    assert_eq!(projects[1].session_count, 0);
    assert_eq!(projects[2].session_count, 2);
    assert_eq!(
        projects[2].last_used_at.as_deref(),
        Some("2026-01-03T00:00:00Z")
    );
}

#[test]
fn recent_projects_capped_at_twenty() {
    let rows: Vec<SessionRow> = (0..30)
        .map(|i| {
            row(
                &format!("s{i}"),
                Some(&format!("/p/{i}")),
                "2026-01-01T00:00:00Z",
            )
        })
        .collect();
    assert_eq!(recent_projects(&[], &rows).len(), MAX_RECENT_PROJECTS);
}

#[test]
fn match_score_orders_prefix_contains_subsequence() {
    let prefix = match_score("src/composer.rs", "compos").unwrap();
    let contains = match_score("src/my_composer.rs", "compos").unwrap();
    let subseq = match_score("src/c/o/m/p/o/s.rs", "compos").unwrap();
    assert!(prefix > contains, "{prefix} > {contains}");
    assert!(contains > subseq, "{contains} > {subseq}");
    assert!(match_score("src/other.rs", "compos").is_none());
    assert!(match_score("README.md", "readme").is_some());
}

#[test]
fn search_relative_honours_gitignore_and_skips_git() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    std::fs::create_dir_all(root.join(".git/objects")).unwrap();
    std::fs::write(root.join(".git/objects/compose_blob"), "").unwrap();
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::create_dir_all(root.join("target")).unwrap();
    std::fs::write(root.join("src/composer.rs"), "").unwrap();
    std::fs::write(root.join("target/composer_ignored.rs"), "").unwrap();
    std::fs::write(root.join(".gitignore"), "target/\n").unwrap();

    let matches = search_relative(root, "compos", 30, false);
    let paths: Vec<&str> = matches.iter().map(|m| m.path.as_str()).collect();
    assert_eq!(paths, vec!["src/composer.rs"], "{paths:?}");

    let dirs = search_relative(root, "sr", 30, true);
    assert_eq!(dirs.len(), 1);
    assert_eq!(dirs[0].path, "src");
    assert!(dirs[0].is_dir);
}

#[test]
fn search_absolute_completes_prefix_and_filters_dirs() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    std::fs::create_dir_all(root.join("alpha")).unwrap();
    std::fs::write(root.join("alphabet.txt"), "").unwrap();
    std::fs::create_dir_all(root.join("beta")).unwrap();

    let query = format!("{}/al", root.display());
    let all = search_absolute(&query, 30, false);
    let paths: Vec<&str> = all.iter().map(|m| m.path.as_str()).collect();
    assert_eq!(paths.len(), 2, "{paths:?}");
    assert!(paths[0].ends_with("/alpha/"), "{paths:?}");
    assert!(paths[1].ends_with("/alphabet.txt"), "{paths:?}");

    let dirs = search_absolute(&query, 30, true);
    assert_eq!(dirs.len(), 1);
    assert!(dirs[0].is_dir);

    let listing = search_absolute(&format!("{}/", root.display()), 30, true);
    assert_eq!(listing.len(), 2);
}
