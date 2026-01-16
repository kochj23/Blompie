#!/usr/bin/env ruby
require 'xcodeproj'

project_path = 'Blompie.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Find the target
target = project.targets.find { |t| t.name == 'Blompie' }

# Find Blompie group
blompie_group = project.main_group['Blompie']

# Create Design group
design_group = blompie_group['Design'] || blompie_group.new_group('Design')

# Add ModernDesign.swift
modern_design_file = design_group.new_file('Design/ModernDesign.swift')
target.source_build_phase.add_file_reference(modern_design_file)

project.save

puts "✅ ModernDesign.swift added to Blompie target"
