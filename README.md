# Terraform Cato Bulk Always-On Rules Module

Bulk-manages the Cato **ZTNA Always-On (ztnaAlwaysOn)** policy from a single
JSON export: sections and rules (flat policy — no sub-policies exist for this
type), with ordering and publishing via `cato_always_on_rule_bulk`.

## Usage

The module reads a JSON configuration file that defines:
- **Rules**: Individual Always-On rules with their configurations
- **Sections**: Logical groupings for organizing rules
- **Rule ordering**: Defines which rules belong to which sections and their order within sections

### Basic Example

```hcl
module "ao_rules" {
  source                  = "catonetworks/bulk-ao-rules/cato"
  ao_rules_json_file_path = "${path.module}/config_data/all_ao_rules_and_sections.json"
}
```

### JSON Configuration Structure

The JSON file should contain a nested structure with the following key components:

- `data.policy.ztnaAlwaysOn.policy.rules[]` - Array of Always-On rules
- `data.policy.ztnaAlwaysOn.policy.sections[]` - Array of sections with index and name
- `data.policy.ztnaAlwaysOn.policy.rules_in_sections[]` - Mapping of rules to sections with ordering

#### Key Fields:

**Rules Array**: Each entry is a `{audit, rule, properties}` wrapper (ids
retained for brownfield import). The `rule` object carries:
- `source{user, usersGroup}` - name/id refs
- `platform[]` - `ANDROID`/`CHROMEOS`/`EMBEDDED`/`IOS`/`LINUX`/`MACOS`/`WINDOWS`
- `devicePostureProfile[]` - name/id refs
- `action` - `ENFORCE`/`IGNORE`
- `allowUserBypass`
- `bypassDuration{time, unit}` - `unit` is `HOURS`/`MINUTES`
- `allowFailOpen`
- `antiTamperMode` - `OFF`/`MONITOR`/`PROTECT`

**Sections Array**: Defines sections with:
- `section_index`: The order of the section in the policy
- `section_name`: The display name of the section

**Rules in Sections Array**: Maps rules to sections with:
- `index_in_section`: The order of the rule within its section
- `section_name`: The section this rule belongs to
- `rule_name`: The name of the rule to place in the section

### How Rule Ordering Works

| Resource | Keyed by | Notes |
|---|---|---|
| `cato_always_on_section.sections` | `section_name` | created `LAST_IN_POLICY`; ordered by the move resource |
| `cato_always_on_rule.rules` | rule name | placement: managed section → `LAST_IN_SECTION`; sectionless → `LAST_IN_POLICY` |
| `cato_always_on_rule_bulk.all_ao_rules` | — | orders sections (`section_index`) and rules (`index_in_section`) and **publishes** |

**Publishing:** `cato_always_on_rule` and `cato_always_on_section` save to the
draft policy only — `cato_always_on_rule_bulk` is the Always-On stack's single
publisher. Without it, applies never go live.

This is a flat policy: no sub-policies exist for this policy type. Both
sectionless (rules at the policy root, `section_name: ""`) and sectioned
shapes are supported. Ordering rows with `section_name: ""` are excluded from
the move resource and surfaced via the `unordered_rules` output; their order
is creation order.

### Parameters

- `ao_rules_json_file_path`: Path to the ZTNA Always-On JSON export produced by `catocli export ao_rules` (`data.policy.ztnaAlwaysOn.policy` root)
- `allow_empty_policy`: (Optional, default `false`) Safety guard — fail planning when the policy JSON contains 0 rules unless explicitly allowed

## Working with Existing Rules (Brownfield Deployments)

For brownfield deployments where you have existing Always-On rules in your Cato Management Application, you can use the Cato CLI to export and import these rules into Terraform state.

### Installing and Configuring Cato CLI

1. **Install the Cato CLI:**
   ```bash
   pip3 install catocli
   ```

2. **Configure the CLI with your Cato credentials:**
   ```bash
   catocli configure set
   ```
   This will prompt you for your Cato Management Application credentials and account information.

### Exporting Existing Rules

To export your existing Always-On rules and sections into the JSON format required by this module:

```bash
catocli export ao_rules --json-filename all_ao_rules_and_sections.json
```

This command will generate a JSON file containing all your existing Always-On rules and sections in the correct format for this Terraform module.

### Importing Existing Rules into Terraform State

The project's standard mechanism for brownfield adoption is Terraform's native
declarative `import` block (Option A, requires Terraform >= 1.7) - it lets you
preview the adoption with `terraform plan` before anything touches state.
The imperative `catocli import ao_rules_to_tf` command (Option B) remains
available as a fallback when native import blocks aren't practical (e.g. an
older Terraform), but it mutates state immediately with no plan preview, so
prefer Option A.

All `for_each` addresses in this module are keyed by name (`section_name` /
rule `name`), which is why the import blocks' map keys line up directly with
the exported JSON.

<details>
<summary>Option A (recommended) — native Terraform import blocks (migration.tf)</summary>

```hcl
# migration.tf — one-shot; delete after a successful `terraform apply` adopts
# the existing rules/sections into state.

locals {
  migrate_json     = jsondecode(file("${path.module}/config_data/all_ao_rules_and_sections.json"))
  migrate_policy   = local.migrate_json.data.policy.ztnaAlwaysOn.policy
  migrate_sections = { for s in local.migrate_policy.sections : s.section_name => s.section_id }
  migrate_rules    = { for rw in local.migrate_policy.rules : rw.rule.name => rw.rule.id }
}

import {
  for_each = local.migrate_sections
  to       = module.ao_rules.cato_always_on_section.sections[each.key]
  id       = each.value
}

import {
  for_each = local.migrate_rules
  to       = module.ao_rules.cato_always_on_rule.rules[each.key]
  id       = each.value
}
```

Preview the adoption before anything touches state:

```bash
terraform plan
```

`terraform plan` against this should show `N to import, 1 to add, 0 to
change, 0 to destroy`. The "1 to add" is expected - it's
`cato_always_on_rule_bulk.all_ao_rules`, which **cannot be imported** (the
provider implements no `ImportState` for it; it's a plan-time
ordering/publish resource with no independent API identity of its own) and is
always created fresh on the first apply after an import. Any *other* "change"
on an imported section/rule means `config_data/...` is stale versus the live
tenant - re-export with `catocli export ao_rules` and diff before applying;
never let Terraform overwrite live policy from an old backup.

Once the plan looks as expected, adopt the resources into state:

```bash
terraform apply
```

This adopts the sections and rules into state (and creates the move/publish
resource, republishing once - a harmless no-op since content already matches
live policy). Delete `migration.tf` afterward — its job is done, and leaving
it in place just re-runs the same (no-op) import blocks on every future plan.

</details>

<details>
<summary>Option B — catocli import ao_rules_to_tf (imperative alternative)</summary>

An imperative alternative to Option A, for when native import blocks aren't practical (e.g. scripting a fully automated onboarding pipeline). Unlike Option A, this mutates Terraform state immediately — there is no plan preview before the import happens.

```bash
catocli import ao_rules_to_tf config_data/all_ao_rules_and_sections.json \
  --module-name module.ao_rules --auto-approve
terraform plan   # expect: only cato_always_on_rule_bulk to add
```

**Parameters:**
- `config_data/all_ao_rules_and_sections.json`: Path to your exported JSON file
- `--module-name module.ao_rules`: The name of your Terraform module instance

</details>

### Typical Brownfield Workflow

1. **Export existing rules:**
   ```bash
   catocli export ao_rules --json-filename all_ao_rules_and_sections.json
   ```

2. **Create your Terraform configuration:**
   ```hcl
   module "ao_rules" {
     source                  = "catonetworks/bulk-ao-rules/cato"
     ao_rules_json_file_path = "${path.module}/config_data/all_ao_rules_and_sections.json"
   }
   ```

3. **Adopt existing state (Option A — recommended):** create `migration.tf` with the import blocks shown above, then:
   ```bash
   terraform plan    # preview: expect "to import" plus the move/publish resource "to add"
   terraform apply   # adopt into state
   ```
   Delete `migration.tf` afterwards. (Option B: `catocli import ao_rules_to_tf config_data/all_ao_rules_and_sections.json --module-name module.ao_rules --auto-approve` — imperative, no plan preview.)

4. **Run Terraform plan to verify:**
   ```bash
   terraform plan
   ```
   This should show no changes if the import was successful.

### Backup and Restore Workflow

If unintended changes are made directly to rules and sections in the Cato Management Application, you can restore to the last known good state:

1. **Apply your last known good configuration:**
   ```bash
   terraform apply
   ```
   This will restore rules and sections to match your Terraform configuration.

2. **Alternatively, re-export and compare:**
   ```bash
   catocli export ao_rules --json-filename all_ao_rules_and_sections.json
   # Compare with your existing JSON file to identify changes
   ```

## Known limitations

- Ordering rows with `section_name: ""` (sectionless policies) are excluded
  from the move resource and surfaced via `unordered_rules`; their order is
  creation order.
- Run applies with `-parallelism=1` when several module instances share an
  account.

## Using Module Outputs

The module provides outputs that can be used for monitoring, auditing, integration with other systems, and operational insights. Below are practical examples of how to use these outputs in your Terraform configuration.

<details>
<summary>Click to expand example client-side outputs</summary>

```hcl
# Basic deployment information
output "deployment_info" {
  description = "Basic information about the Always-On deployment"
  value = {
    total_sections = module.ao_rules.deployment_summary.sections
    total_rules    = module.ao_rules.deployment_summary.rules
  }
}

# Quick reference for rule and section IDs
output "quick_reference" {
  description = "Quick reference maps for rules and sections"
  value = {
    section_ids = module.ao_rules.section_ids
    rule_ids    = module.ao_rules.rule_ids
  }
}

# Example: Rules that might need attention
output "rules_needing_attention" {
  description = "rules_in_sections rows the move resource couldn't order (sectionless policies)"
  value = {
    unordered_rules       = module.ao_rules.unordered_rules
    unordered_rules_count = length(module.ao_rules.unordered_rules)
  }
}

# Example: For integration with monitoring systems
output "monitoring_metrics" {
  description = "Example metrics that could be sent to monitoring systems"
  value = {
    deployment_timestamp = timestamp()
    total_ao_sections    = module.ao_rules.deployment_summary.sections
    total_ao_rules       = module.ao_rules.deployment_summary.rules
    unordered_rules      = length(module.ao_rules.unordered_rules)
  }
}
```
</details>

### Output Use Cases

These example outputs demonstrate various practical applications:

- **`deployment_info`**: Quick deployment overview for dashboards
- **`quick_reference`**: ID mappings for referencing resources in other modules
- **`rules_needing_attention`**: Identifying sectionless rules the move resource can't order, for review
- **`monitoring_metrics`**: Metrics formatted for monitoring systems

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_cato"></a> [cato](#requirement\_cato) | >= 1.3.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cato"></a> [cato](#provider\_cato) | >= 1.3.1 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [cato_always_on_rule.rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/always_on_rule) | resource |
| [cato_always_on_rule_bulk.all_ao_rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/always_on_rule_bulk) | resource |
| [cato_always_on_section.sections](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/always_on_section) | resource |
| [terraform_data.guard_empty_policy](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allow_empty_policy"></a> [allow\_empty\_policy](#input\_allow\_empty\_policy) | Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown. | `bool` | `false` | no |
| <a name="input_ao_rules_json_file_path"></a> [ao\_rules\_json\_file\_path](#input\_ao\_rules\_json\_file\_path) | Path to the ZTNA Always-On JSON export produced by `catocli export ao_rules` (data.policy.ztnaAlwaysOn.policy root). | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_deployment_summary"></a> [deployment\_summary](#output\_deployment\_summary) | Counts of managed Always-On objects. |
| <a name="output_rule_ids"></a> [rule\_ids](#output\_rule\_ids) | Map of rule name to rule id. |
| <a name="output_section_ids"></a> [section\_ids](#output\_section\_ids) | Map of section name to section id. |
| <a name="output_unordered_rules"></a> [unordered\_rules](#output\_unordered\_rules) | rules\_in\_sections rows excluded from cato\_always\_on\_rule\_bulk (no managed section to order within). |
<!-- END_TF_DOCS -->
