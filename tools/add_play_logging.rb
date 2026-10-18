#!/usr/bin/env ruby
# Play-history logging (Nova Games DB): links PostgresNIO into the Blompie app target, adds Blompie/Storage/*.swift,
# bundles the games-pg CA (public cert) and adds BlompieTests/PlayLoggerTests.swift. Idempotent.
# Run from the repo root: ruby tools/add_play_logging.rb
require 'xcodeproj'

project = Xcodeproj::Project.open('Blompie.xcodeproj')
app = project.targets.find { |t| t.name == 'Blompie' } or abort 'no Blompie target'
tests = project.targets.find { |t| t.name == 'BlompieTests' } or abort 'no BlompieTests target'

url = 'https://github.com/vapor/postgres-nio.git'
ref = project.root_object.package_references.find { |r| r.respond_to?(:repositoryURL) && r.repositoryURL == url }
unless ref
  ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  ref.repositoryURL = url
  ref.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '1.33.1' }
  project.root_object.package_references << ref
end
unless app.package_product_dependencies.any? { |d| d.product_name == 'PostgresNIO' }
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = ref
  dep.product_name = 'PostgresNIO'
  app.package_product_dependencies << dep
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  app.frameworks_build_phase.files << bf
end

group = project.main_group['Blompie']
storage = group['Storage'] || group.new_group('Storage', 'Storage')
Dir['Blompie/Storage/*.swift'].sort.each do |path|
  name = File.basename(path)
  fref = storage.files.find { |f| f.path == name } || storage.new_file(name)
  app.source_build_phase.add_file_reference(fref, true) unless app.source_build_phase.files_references.include?(fref)
end
ca = storage.files.find { |f| f.path == 'games-pg-ca.crt' } || storage.new_file('games-pg-ca.crt')
app.resources_build_phase.add_file_reference(ca, true) unless app.resources_build_phase.files_references.include?(ca)

tgroup = project.main_group['BlompieTests']
tname = 'PlayLoggerTests.swift'
tref = tgroup.files.find { |f| f.path == tname || f.path == "BlompieTests/#{tname}" } || tgroup.new_file(tname)
tests.source_build_phase.add_file_reference(tref, true) unless tests.source_build_phase.files_references.include?(tref)

project.save
puts 'play logging linked: PostgresNIO, Storage/*.swift, games-pg-ca.crt, PlayLoggerTests.swift'
