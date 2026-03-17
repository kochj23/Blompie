#!/usr/bin/env ruby
# Fix code signing for Blompie
# Created by Jordan Koch

require 'xcodeproj'

project_path = '/Volumes/Data/xcode/Blompie/Blompie.xcodeproj'
project = Xcodeproj::Project.open(project_path)

puts "Fixing code signing..."

project.targets.each do |target|
  puts "Target: #{target.name}"
  target.build_configurations.each do |config|
    config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
    config.build_settings['DEVELOPMENT_TEAM'] = 'QRRCB8HB3W'
    config.build_settings['CODE_SIGN_IDENTITY'] = 'Apple Development'
  end
end

project.save
puts "Code signing fixed!"
