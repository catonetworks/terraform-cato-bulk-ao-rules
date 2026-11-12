# Changelog

## 0.0.1 (2026-11-04)

### Features
- Initial release: bulk management of ZTNA Always-On (ztnaAlwaysOn) rules &
  sections from a catocli JSON export, with name-keyed state addressing.
- Added `allow_empty_policy` safety guard — planning fails when the policy
  JSON contains 0 rules unless explicitly allowed, protecting against
  truncated or wrong-tenant exports mass-destroying a live policy.
- README: brownfield import documentation covers two options — native
  Terraform `import` blocks (recommended, declarative/previewable) and the
  `catocli import ao_rules_to_tf` imperative alternative.
