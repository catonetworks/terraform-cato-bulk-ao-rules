# terraform-cato-bulk-ao-rules

Bulk-manages the Cato **ZTNA Always-On (ztnaAlwaysOn)** policy from a single
JSON export: sections and rules (flat policy — no sub-policies exist for this
type), with ordering and publishing via `cato_bulk_ao_move_rule`.

## Resources managed

| Resource | Keyed by | Notes |
|---|---|---|
| `cato_always_on_section.sections` | `section_name` | created `LAST_IN_POLICY`; ordered by the move resource |
| `cato_always_on_rule.rules` | rule name | placement: managed section → `LAST_IN_SECTION`; sectionless → `LAST_IN_POLICY` |
| `cato_bulk_ao_move_rule.all_ao_rules` | — | orders sections (`section_index`) and rules (`index_in_section`) and **publishes** |

**Publishing:** `cato_always_on_rule` and `cato_always_on_section` save to the
draft policy only — `cato_bulk_ao_move_rule` is the Always-On stack's single
publisher. Without it, applies never go live.

## Input JSON

```bash
catocli export ao_rules --json-filename all_ao_rules_and_sections.json
```

Root: `data.policy.ztnaAlwaysOn.policy` with `sections[]`, `rules[]`
(wrappers `{audit, rule, properties}`, ids retained for brownfield import),
and `rules_in_sections[]`. Rule fields: `source{user, usersGroup}` (id/name
refs), `platform[]` (ANDROID/CHROMEOS/EMBEDDED/IOS/LINUX/MACOS/WINDOWS),
`devicePostureProfile[]`, `action` (ENFORCE/IGNORE), `allowUserBypass`,
`bypassDuration{time, unit HOURS|MINUTES}`, `allowFailOpen`, `antiTamperMode`
(OFF/MONITOR/PROTECT).

## Usage

```hcl
module "ao_rules" {
  source                  = "catonetworks/bulk-ao-rules/cato"
  ao_rules_json_file_path = "${path.module}/config_data/all_ao_rules_and_sections.json"
}
```

## Brownfield import

```bash
catocli import ao_rules_to_tf config_data/all_ao_rules_and_sections.json \
  --module-name module.ao_rules --auto-approve
terraform plan   # expect: only cato_bulk_ao_move_rule to add
```

## Known limitations

- Ordering rows with `section_name: ""` (sectionless policies) are excluded
  from the move resource and surfaced via `unordered_rules`; their order is
  creation order.
- Run applies with `-parallelism=1` when several module instances share an
  account.
