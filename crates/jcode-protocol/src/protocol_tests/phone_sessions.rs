#[test]
fn wire_list_sessions_request_roundtrip() -> Result<()> {
    let decoded = parse_request_json(r#"{"id":7,"type":"list_sessions","limit":100,"include_workers":false}"#)?;
    let Request::ListSessions {
        id,
        limit,
        include_workers,
    } = decoded
    else {
        return Err(anyhow!("wrong request type"));
    };
    assert_eq!((id, limit, include_workers), (7, Some(100), false));

    // Bare form: limit and include_workers are optional.
    let bare = parse_request_json(r#"{"id":1,"type":"list_sessions"}"#)?;
    assert!(matches!(
        bare,
        Request::ListSessions {
            id: 1,
            limit: None,
            include_workers: false
        }
    ));
    let json = serde_json::to_string(&bare)?;
    assert_eq!(json, r#"{"type":"list_sessions","id":1}"#);
    Ok(())
}

#[test]
fn wire_close_session_request_roundtrip() -> Result<()> {
    let req = Request::CloseSession {
        id: 8,
        session_id: "session_fox_1".to_string(),
        delete: true,
    };
    let json = serde_json::to_string(&req)?;
    assert!(json.contains(r#""type":"close_session""#));
    assert!(json.contains(r#""delete":true"#));
    let decoded = parse_request_json(&json)?;
    let Request::CloseSession {
        id,
        session_id,
        delete,
    } = decoded
    else {
        return Err(anyhow!("wrong request type"));
    };
    assert_eq!((id, session_id.as_str(), delete), (8, "session_fox_1", true));
    let no_delete = parse_request_json(r#"{"id":2,"type":"close_session","session_id":"x"}"#)?;
    assert!(matches!(no_delete, Request::CloseSession { delete: false, .. }));
    Ok(())
}

#[test]
fn wire_search_files_request_roundtrip() -> Result<()> {
    let decoded = parse_request_json(
        r#"{"id":9,"type":"search_files","query":"compos","limit":30,"dirs_only":false,"working_dir":null}"#,
    )?;
    let Request::SearchFiles {
        id,
        query,
        limit,
        dirs_only,
        working_dir,
    } = decoded
    else {
        return Err(anyhow!("wrong request type"));
    };
    assert_eq!(id, 9);
    assert_eq!(query, "compos");
    assert_eq!(limit, Some(30));
    assert!(!dirs_only);
    assert_eq!(working_dir, None);

    let req = Request::SearchFiles {
        id: 3,
        query: "/Users/".to_string(),
        limit: None,
        dirs_only: true,
        working_dir: Some("/tmp".to_string()),
    };
    let json = serde_json::to_string(&req)?;
    assert_eq!(
        json,
        r#"{"type":"search_files","id":3,"query":"/Users/","dirs_only":true,"working_dir":"/tmp"}"#
    );
    Ok(())
}

#[test]
fn wire_sessions_event_roundtrip() -> Result<()> {
    let event = ServerEvent::Sessions {
        id: 7,
        server_name: "work-mini".to_string(),
        server_icon: "🔥".to_string(),
        server_version: "v0.85.0 (abc1234)".to_string(),
        sessions: vec![SessionRow {
            id: "session_fox_1".to_string(),
            short_name: Some("fox".to_string()),
            title: Some("Fix the queue bar".to_string()),
            working_dir: Some("/Users/dpfurner/dev/jed".to_string()),
            created_at: "2026-09-15T18:45:33Z".to_string(),
            updated_at: "2026-09-15T18:51:41Z".to_string(),
            last_active_at: None,
            model: Some("claude-opus-4".to_string()),
            provider: Some("claude".to_string()),
            phase: "needs_you".to_string(),
            reason: Some("waiting for input".to_string()),
            current_tool: Some("ask_user".to_string()),
            turn_started_at: Some("2026-09-15T18:50:02Z".to_string()),
            queued: 1,
            pending_prompt: None,
            preview: Some(PreviewInfo {
                kind: "prompt".to_string(),
                text: "Which DB?".to_string(),
            }),
            client_count: 1,
            is_live: true,
            parent_id: None,
            swarm_role: None,
        }],
        recent_projects: vec![RecentProject {
            path: "/Users/dpfurner/dev/jed".to_string(),
            last_used_at: Some("2026-09-15T18:51:41Z".to_string()),
            session_count: 41,
        }],
    };
    let json = serde_json::to_string(&event)?;
    assert!(json.starts_with(r#"{"type":"sessions","id":7"#), "{json}");
    // pending_prompt is always present so clients can key on it.
    assert!(json.contains(r#""pending_prompt":null"#), "{json}");
    assert!(!json.contains("last_active_at"), "{json}");
    let decoded = parse_event_json(&json)?;
    let ServerEvent::Sessions {
        sessions,
        recent_projects,
        ..
    } = decoded
    else {
        return Err(anyhow!("wrong event type"));
    };
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].phase, "needs_you");
    assert_eq!(recent_projects[0].session_count, 41);
    Ok(())
}

#[test]
fn wire_session_closed_event_roundtrip() -> Result<()> {
    let event = ServerEvent::SessionClosed {
        id: 8,
        session_id: "session_fox_1".to_string(),
        deleted: false,
    };
    let json = serde_json::to_string(&event)?;
    assert_eq!(
        json,
        r#"{"type":"session_closed","id":8,"session_id":"session_fox_1","deleted":false}"#
    );
    assert!(matches!(
        parse_event_json(&json)?,
        ServerEvent::SessionClosed { id: 8, deleted: false, .. }
    ));
    Ok(())
}

#[test]
fn wire_file_matches_event_roundtrip() -> Result<()> {
    let event = ServerEvent::FileMatches {
        id: 9,
        query: "compos".to_string(),
        matches: vec![
            FileMatch {
                path: "Sources/ComposerView.swift".to_string(),
                is_dir: false,
            },
            FileMatch {
                path: "Sources/Composer".to_string(),
                is_dir: true,
            },
        ],
    };
    let json = serde_json::to_string(&event)?;
    assert_eq!(
        json,
        r#"{"type":"file_matches","id":9,"query":"compos","matches":[{"path":"Sources/ComposerView.swift"},{"path":"Sources/Composer","is_dir":true}]}"#
    );
    let ServerEvent::FileMatches { matches, .. } = parse_event_json(&json)? else {
        return Err(anyhow!("wrong event type"));
    };
    assert_eq!(matches.len(), 2);
    assert!(!matches[0].is_dir);
    assert!(matches[1].is_dir);
    Ok(())
}
