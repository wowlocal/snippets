# iOS secure-body accessibility containment

UIKit does not provide the protected-content accessibility-client filtering that the
macOS secure editor uses. Snippets therefore fails closed on iPhone and iPad: a
`SecureSnippetTextView` and its descendants are excluded from the accessibility tree for
the entire secure session, including while authenticated plaintext is visually shown.
Its label, value, hint, attributed variants, user-input labels, and textual context are
also redacted. Protection is enabled before plaintext enters the text view, and the text
storage is cleared before ordinary accessibility is restored.

Both editors expose a separate metadata-free sibling element. It says only that the
secure body is protected and whether it can be revealed or is currently shown visually;
it never receives the body, name, keyword, or tags.

## Intentional VoiceOver tradeoff

VoiceOver, Voice Control, Switch Control, and UI-automation clients cannot read, select,
or directly edit a secure snippet body, even after its pixels are revealed. This is an
intentional confidentiality tradeoff imposed by the absence of a public UIKit API that
can distinguish trusted assistive clients from arbitrary accessibility inspection.
Metadata fields remain accessible because secure names, keywords, and tags are already
part of the searchable secure shell. Ordinary snippet text views retain normal UIKit
accessibility.

This containment is an exposure reduction, not a claim that plaintext is inaccessible
to privileged/debugging software. Screen capture and physical-observation mitigations are
separate controls and are verified separately.
