# Recipe: Launch Readiness With Weighted Goals

Use this recipe when a project has enough specs that a plain checklist
is misleading. The example models a media upload launch where product,
safety, and sharing work advance at different speeds.

The recipe assumes:

- `pkspec check --discover` is already part of CI.
- Scenarios have stable ids and `reviewStatus`.
- Implementing tests live in separate `Test.pkl` files and link back
  with `specRef`.

## 1. Model Product Value As Goals

Put durable product value in Goals. Use `severity-weighted` only for
Goals where missing critical Scenarios should dominate the percentage.

```pkl
// specs/upload-launch.pkl
amends "../pkspec/Spec.pkl"

feature = "media upload launch readiness"

goals {
  new Goal {
    id = "goal.upload-core"
    name = "users can upload supported media"
    priority = 95
    reviewStatus = "approved"
    description = "Users can add images, GIFs, SVGs, and videos from the web UI and CLI."
  }

  new Goal {
    id = "goal.upload-safety"
    name = "uploads are safe to serve"
    priority = 90
    reviewStatus = "approved"
    description = "Unsafe or unsupported media is rejected before it reaches public URLs."
    progress {
      method = "severity-weighted"
    }
  }

  new Goal {
    id = "goal.upload-share"
    name = "uploaded media is easy to share"
    priority = 70
    reviewStatus = "review"
    description = "The UI can generate Markdown and HTML links with useful alt text."
  }
}
```

## 2. Group Goals Into Milestones

Use Milestones for release checkpoints. Keep the beta Milestone
stakeholder-friendly with `goal-average`; use a separate hardening
Milestone when engineering wants a severity-weighted burn-down.

```pkl
milestones {
  new Milestone {
    id = "ms.upload-beta"
    name = "upload beta"
    targetDate = "2026-06-01"
    reviewStatus = "review"
    description = "Enough upload functionality to dogfood in another service."
    goals {
      "goal.upload-core"
      "goal.upload-safety"
      "goal.upload-share"
    }
    progressMethod = "goal-average"
  }

  new Milestone {
    id = "ms.upload-hardening"
    name = "upload safety hardening"
    targetDate = "2026-06-15"
    reviewStatus = "draft"
    goals { "goal.upload-safety" }
    progressMethod = "severity-weighted"
  }
}
```

## 3. Write Scenarios Once

Scenarios should contribute to Goals, not directly to Milestones. This
keeps planning views derived from the spec graph instead of becoming a
second checklist to maintain.

```pkl
scenarios {
  new Scenario {
    id = "upload.web-dnd"
    name = "web_drag_and_drop_upload"
    description = "The browser UI accepts drag-and-drop image and video uploads."
    severity = "critical"
    reviewStatus = "approved"
    contributes { "goal.upload-core" }
  }

  new Scenario {
    id = "upload.cli-file"
    name = "cli_file_upload"
    description = "The CLI uploads a file path and prints the created asset URL."
    severity = "major"
    reviewStatus = "approved"
    contributes { "goal.upload-core" }
  }

  new Scenario {
    id = "upload.reject-html"
    name = "reject_html_disguised_as_svg"
    description = "SVG uploads are sanitized so embedded active content is not served."
    severity = "critical"
    reviewStatus = "approved"
    contributes { "goal.upload-safety" }
  }

  new Scenario {
    id = "upload.reject-large-video"
    name = "reject_video_over_limit"
    description = "Oversized MP4 uploads fail with a clear validation error."
    severity = "major"
    reviewStatus = "review"
    contributes { "goal.upload-safety" }
  }

  new Scenario {
    id = "upload.markdown-link"
    name = "generate_markdown_link"
    description = "The upload detail page copies a Markdown link with AI-generated alt text."
    severity = "minor"
    reviewStatus = "review"
    contributes { "goal.upload-share" }
  }
}
```

## 4. Link Implementations From Tests

Keep implementation details in `Test.pkl`. The spec file remains the
planning and review surface.

```pkl
// tests/upload-ui.pkl
amends "../pkspec/Test.pkl"

tests {
  new {
    name = "web_dnd_upload_accepts_video"
    specRef { "upload.web-dnd" }
    cmd = "pnpm test:e2e -- upload-dnd.spec.ts"
    tags { "e2e"; "upload" }
  }

  new {
    name = "markdown_link_button_uses_alt_text"
    specRef { "upload.markdown-link" }
    cmd = "pnpm test:e2e -- upload-link.spec.ts"
    tags { "e2e"; "upload" }
  }
}
```

## 5. Review The Project

Run the same commands in local review and CI:

```sh
pkspec lint --discover
pkspec check --strict --discover
pkspec goals --discover
pkspec milestones --discover
pkspec next --discover
```

Read them as separate views:

- `lint` answers "is the planning graph structurally valid?"
- `check --strict` answers "are approved specs implemented?"
- `goals` answers "which user-value targets are close?"
- `milestones` answers "is the launch checkpoint ready?"
- `next` answers "which unimplemented spec should be picked first?"

## 6. Interpret The Percentages

If `goal.upload-safety` has one implemented major Scenario and one open
critical Scenario, `severity-weighted` reports `3 / 8` instead of
`1 / 2`. That is intentional: the critical safety hole should dominate
the launch-readiness signal.

For `ms.upload-beta`, `goal-average` means each Goal contributes one
third of the Milestone percentage. This is usually the right product
view. If the team wants an engineering burn-down, add a second
Milestone with `progressMethod = "severity-weighted"` rather than
changing the stakeholder view.

## Common Pitfalls

Do not add Scenario ids directly to a Milestone. Milestones reference
Goals only; Scenarios flow in through `contributes`.

Do not compare two percentages without checking their method. A
`scenario-count` Goal and a `severity-weighted` Goal can have the same
percentage for different reasons.

Do not leave stale Milestones forever. Once a launch checkpoint is no
longer useful, set `deprecated = true` and create the next checkpoint.

Do not use pkspec percentages as product analytics. They measure spec
implementation status, not user adoption, traffic, or reliability in
production.
