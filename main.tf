# terraform-cato-bulk-ao-rules
#
# Bulk-manages the Cato ZTNA Always-On (ztnaAlwaysOn) policy from one JSON
# export produced by `catocli export ao_rules`:
#   sections[]           flat sections ({section_index, section_name, section_id})
#   rules[]              rule wrappers ({audit, rule, properties}; ids retained
#                        for brownfield import)
#   rules_in_sections[]  THE ordering table (sections <-> rules)
#
# Flat policy: no sub-policies exist for this policy type. Supported shapes:
# sectionless (rules at the policy root, section_name "") and sectioned.
#
# Publishing: cato_always_on_rule / cato_always_on_section save to the DRAFT
# policy only; cato_bulk_ao_move_rule below is the stack's single publisher.

locals {
  ao_json = jsondecode(file("${var.ao_rules_json_file_path}"))
  ao      = local.ao_json.data.policy.ztnaAlwaysOn.policy

  sections_data_raw      = try(local.ao.sections, [])
  rules_data_raw         = try(local.ao.rules, [])
  rules_in_sections_data = try(local.ao.rules_in_sections, [])

  sections_data = {
    for s in local.sections_data_raw : s.section_name => s
  }

  rules_by_name = {
    for rw in local.rules_data_raw : rw.rule.name => rw
  }

  # Move-resource inputs. Rows whose section is unmanaged (section_name "" -
  # sectionless policies) are excluded and surfaced via unordered_rules:
  # the move resource orders rules through sections.
  move_section_data = {
    for name, s in local.sections_data : name => {
      section_index = s.section_index
    }
  }

  move_rule_data = {
    for row in local.rules_in_sections_data :
    row.rule_name => {
      index_in_section = row.index_in_section
      section_name     = row.section_name
    }
    if row.section_name != "" && contains(keys(local.sections_data), row.section_name)
  }

  unordered_rules_data = [
    for row in local.rules_in_sections_data : row
    if !contains(keys(local.move_rule_data), try(row.rule_name, ""))
  ]

  # Rule-body construction (API camelCase -> provider snake_case). Entity refs
  # are name-or-id ({name} from the exporter; {id} when the live name contains
  # a backslash). source/user refs: empty sets mean "any" and the provider
  # requires the attributes - always passed.
  rule_bodies = {
    for name, rw in local.rules_by_name : name => merge(
      {
        name              = rw.rule.name
        description       = try(rw.rule.description, "")
        enabled           = try(rw.rule.enabled, true)
        action            = try(rw.rule.action, "ENFORCE")
        allow_user_bypass = try(rw.rule.allowUserBypass, false)
        allow_fail_open   = try(rw.rule.allowFailOpen, false)
        anti_tamper_mode  = try(rw.rule.antiTamperMode, "OFF")
        bypass_duration = {
          time = try(rw.rule.bypassDuration.time, 15)
          unit = try(rw.rule.bypassDuration.unit, "MINUTES")
        }
        platform = try(rw.rule.platform, [])
        device_posture_profile = [
          for x in try(rw.rule.devicePostureProfile, []) :
          can(x.name) ? { name = x.name } : { id = x.id }
        ]
        source = {
          users = [
            for x in try(rw.rule.source.user, []) :
            can(x.name) ? { name = x.name } : { id = x.id }
          ]
          user_groups = [
            for x in try(rw.rule.source.usersGroup, []) :
            can(x.name) ? { name = x.name } : { id = x.id }
          ]
        }
      }
    )
  }
}

resource "cato_always_on_section" "sections" {
  for_each = local.sections_data
  at = {
    position = "LAST_IN_POLICY"
  }
  section = {
    name = each.value.section_name
  }
}

resource "cato_always_on_rule" "rules" {
  depends_on = [cato_always_on_section.sections]
  for_each   = local.rules_by_name

  at = contains(keys(local.sections_data), each.value.rule.section.name) ? {
    position = "LAST_IN_SECTION"
    ref      = cato_always_on_section.sections[each.value.rule.section.name].id
    } : {
    position = "LAST_IN_POLICY"
  }

  rule = local.rule_bodies[each.key]
}

# Ordering + the Always-On stack's ONLY publish.
resource "cato_bulk_ao_move_rule" "all_ao_rules" {
  depends_on = [cato_always_on_section.sections, cato_always_on_rule.rules]

  section_data = local.move_section_data
  rule_data    = local.move_rule_data
}
