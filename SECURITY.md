# Security policy

Operon processes private application data and may eventually invoke tools with
side effects. Security reports should not be filed as public issues. Until a
dedicated security address is published, contact the repository owner privately
through GitHub.

## Security invariants

- The portable core has no ambient network, filesystem, or platform authority.
- Cloud execution requires an explicit application policy.
- Grounding sources and tool outputs are untrusted input.
- Model output never directly authorizes a side effect.
- Tools validate generated arguments before acting.
- Safe traces omit prompts, source contents, model output, secrets, and personal
  data by default.

The project is pre-1.0. Supported release lines and response timelines will be
defined before the first public developer preview.
