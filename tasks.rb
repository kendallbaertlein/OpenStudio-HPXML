command_list = [:update_measures]

def display_usage(command_list)
  puts "Usage: openstudio #{File.basename(__FILE__)} [COMMAND]\nCommands:\n  " + command_list.join("\n  ")
end

if ARGV.size == 0
  puts "ERROR: Missing command."
  display_usage(command_list)
  exit!
elsif ARGV.size > 1
  puts "ERROR: Too many commands."
  display_usage(command_list)
  exit!
elsif not command_list.include? ARGV[0].to_sym
  puts "ERROR: Invalid command '#{ARGV[0]}'."
  display_usage(command_list)
  exit!
end

if ARGV[0].to_sym == :update_measures
  require 'openstudio'

  # Prevent NREL error regarding U: drive when not VPNed in
  ENV['HOME'] = 'C:' if !ENV['HOME'].nil? and ENV['HOME'].start_with? 'U:'
  ENV['HOMEDRIVE'] = 'C:\\' if !ENV['HOMEDRIVE'].nil? and ENV['HOMEDRIVE'].start_with? 'U:'

  # Apply rubocop
  command = "rubocop --auto-correct --format simple --only Layout"
  puts "Applying rubocop style to measures..."
  system(command)

  # Update measures XMLs
  command = "#{OpenStudio.getOpenStudioCLI} measure -t '#{File.join(File.dirname(__FILE__), 'rulesets')}'"
  puts "Updating measure.xmls..."
  system(command, [:out, :err] => File::NULL)

  puts "Done."
end
