#!/usr/bin/env ruby
# Patches the Xcode project so the "Embed Foundation Extensions" build phase
# only runs on iOS. Without this patch, the macOS app build fails with:
#   "embedded content built for iOS not allowed"
#
# Root cause: xcodegen 2.45.4 does not emit `platformFilters = (ios,);` on the
# PBXBuildFile for app-extension embeds, even when `platformFilter: ios` is set
# on the dependency in project.yml. This script sets it post-generate.
#
# Idempotent — safe to re-run. Already-patched build files are left unchanged.
#
# Mirrors the style of scripts/add-ui-test-target.rb (xcodeproj gem).
#
# Requires the `xcodeproj` gem:
#   gem install xcodeproj --user-install

require 'xcodeproj'

PROJECT_PATH     = File.expand_path('../FenixKanban.xcodeproj', __dir__)
APP_TARGET_NAME  = 'FenixKanban'
EXTENSION_NAME   = 'FenixKanbanWidgets'
EMBED_PHASE_NAME = 'Embed Foundation Extensions'
IOS_FILTER       = 'ios'

project = Xcodeproj::Project.open(PROJECT_PATH)

app_target = project.targets.find { |t| t.name == APP_TARGET_NAME }
raise "Target '#{APP_TARGET_NAME}' not found in #{PROJECT_PATH}" unless app_target

embed_phase = app_target.copy_files_build_phases.find { |p| p.name == EMBED_PHASE_NAME }
unless embed_phase
  puts "No '#{EMBED_PHASE_NAME}' phase found on #{APP_TARGET_NAME} — nothing to patch."
  exit 0
end

patched = 0
embed_phase.files.each do |build_file|
  ref = build_file.file_ref
  next unless ref && ref.path&.end_with?("#{EXTENSION_NAME}.appex")

  already_filtered = Array(build_file.platform_filters).include?(IOS_FILTER) ||
                     build_file.platform_filter == IOS_FILTER

  unless already_filtered
    build_file.platform_filters = [IOS_FILTER]
    patched += 1
    puts "Patched platformFilters = [\"#{IOS_FILTER}\"] on #{ref.path} in '#{EMBED_PHASE_NAME}'"
  end
end

if patched > 0
  project.save
  puts "Saved #{PROJECT_PATH} (#{patched} build file(s) patched)"
else
  puts "#{EXTENSION_NAME}.appex embed already has platformFilters set — no changes needed"
end
