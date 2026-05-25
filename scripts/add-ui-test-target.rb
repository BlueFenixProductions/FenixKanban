#!/usr/bin/env ruby
# Adds (or refreshes) the FenixKanbanUITests target on the FenixKanban Xcode
# project. Idempotent — safe to re-run.
#
# Run once when checking out the repo for the first time after this script
# lands. CI workflows should also call it before `xcodebuild test` so the
# target is present even on fresh agents.
#
# Requires the `xcodeproj` gem:
#   gem install xcodeproj --user-install

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../FenixKanban.xcodeproj', __dir__)
UI_TEST_TARGET_NAME = 'FenixKanbanUITests'
UI_TEST_DIR = 'FenixKanbanUITests'
APP_TARGET_NAME = 'FenixKanban'

project = Xcodeproj::Project.open(PROJECT_PATH)

app_target = project.targets.find { |t| t.name == APP_TARGET_NAME }
raise "App target #{APP_TARGET_NAME} not found" unless app_target

existing = project.targets.find { |t| t.name == UI_TEST_TARGET_NAME }
if existing
  puts "Removing existing #{UI_TEST_TARGET_NAME} target so we recreate it cleanly"
  # Remove product reference from the Products group too
  product_ref = existing.product_reference
  product_ref.remove_from_project if product_ref
  existing.remove_from_project
end

ui_test_target = project.new_target(
  :ui_test_bundle,
  UI_TEST_TARGET_NAME,
  :ios,
  '26.0',
  project.products_group,
  :swift
)

# UI tests link against the app under test, not run inside it like unit tests.
# TEST_TARGET_NAME is what tells Xcode which app this UI test bundle drives.
ui_test_target.build_configurations.each do |config|
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER'   => 'com.bluefenixproductions.FenixKanbanUITests',
    'TEST_TARGET_NAME'            => APP_TARGET_NAME,
    'TARGETED_DEVICE_FAMILY'      => '1,2',
    'SUPPORTED_PLATFORMS'         => 'iphoneos iphonesimulator',
    'SDKROOT'                     => 'iphoneos',
    'IPHONEOS_DEPLOYMENT_TARGET'  => '26.0',
    'GENERATE_INFOPLIST_FILE'     => 'YES',
    'SWIFT_VERSION'               => '5.9',
    'CODE_SIGN_STYLE'             => 'Automatic',
    # UI tests can't run under Mac Catalyst with this target's design;
    # macOS verification stays on the unit-test target.
    'SUPPORTS_MACCATALYST'        => 'NO'
  )
end

ui_test_target.add_dependency(app_target)

# Wire up the source group + file.
ui_test_group = project.main_group[UI_TEST_DIR] ||
                project.main_group.new_group(UI_TEST_DIR, UI_TEST_DIR)
source_path = File.join(UI_TEST_DIR, 'FenixKanbanUITests.swift')
file_ref = ui_test_group.files.find { |f| f.path == 'FenixKanbanUITests.swift' } ||
           ui_test_group.new_reference('FenixKanbanUITests.swift')
ui_test_target.add_file_references([file_ref]) unless
  ui_test_target.source_build_phase.files_references.include?(file_ref)

project.save

# Shared scheme so `xcodebuild test -scheme FenixKanban` discovers
# both the unit and UI test bundles (the auto-generated user scheme
# only sees what existed when the project was first opened).
unit_test_target = project.targets.find { |t| t.name == 'FenixKanbanTests' }
raise 'FenixKanbanTests target missing — cannot build scheme' unless unit_test_target

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app_target)
scheme.add_test_target(unit_test_target)
scheme.add_test_target(ui_test_target)
scheme.set_launch_target(app_target)
scheme.save_as(PROJECT_PATH, APP_TARGET_NAME, true)

puts "Added/refreshed UI test target: #{UI_TEST_TARGET_NAME}"
puts "Source: #{source_path}"
puts "Shared scheme written for: #{APP_TARGET_NAME}"
