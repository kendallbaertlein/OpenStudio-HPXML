start_time = Time.now

require 'fileutils'
require 'optparse'
require 'pathname'
require 'csv'
require_relative '../hpxml-measures/HPXMLtoOpenStudio/resources/meta_measure'

basedir = File.expand_path(File.dirname(__FILE__))

def rm_path(path)
  if Dir.exist?(path)
    FileUtils.rm_r(path)
  end
  while true
    break if not Dir.exist?(path)

    sleep(0.01)
  end
end

def get_rundir(output_dir, design)
  return File.join(output_dir, design.gsub(' ', ''))
end

def get_output_hpxml_path(resultsdir, rundir)
  return File.join(resultsdir, File.basename(rundir) + '.xml')
end

def run_design(basedir, rundir, design, resultsdir, hpxml, debug, skip_simulation)
  puts 'Creating input...'

  Dir.mkdir(rundir)

  OpenStudio::Logger.instance.standardOutLogger.setLogLevel(OpenStudio::Fatal)

  output_hpxml_path = get_output_hpxml_path(resultsdir, rundir)

  model = OpenStudio::Model::Model.new
  runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
  measures_dir = File.join(basedir, '..')

  measures = {}

  # Add HEScore measure to workflow
  measure_subdir = 'rulesets/HEScoreRuleset'
  args = {}
  args['hpxml_path'] = hpxml
  args['hpxml_output_path'] = output_hpxml_path
  update_args_hash(measures, measure_subdir, args)

  if not skip_simulation
    # Add HPXML translator measure to workflow
    measure_subdir = 'hpxml-measures/HPXMLtoOpenStudio'
    args = {}
    args['hpxml_path'] = output_hpxml_path
    args['weather_dir'] = File.absolute_path(File.join(basedir, '..', 'weather'))
    args['output_dir'] = rundir
    args['debug'] = debug
    update_args_hash(measures, measure_subdir, args)

    # Add reporting measure to workflow
    measure_subdir = 'hpxml-measures/SimulationOutputReport'
    args = {}
    args['timeseries_frequency'] = 'monthly'
    args['include_timeseries_zone_temperatures'] = false
    args['include_timeseries_fuel_consumptions'] = false
    args['include_timeseries_end_use_consumptions'] = true
    args['include_timeseries_total_loads'] = false
    args['include_timeseries_component_loads'] = false
    update_args_hash(measures, measure_subdir, args)
  end

  # Apply measures
  success = apply_measures(measures_dir, measures, runner, model, true, 'OpenStudio::Measure::ModelMeasure')
  report_measure_errors_warnings(runner, rundir, debug)

  return if skip_simulation

  if not success
    fail 'Simulation unsuccessful.'
  end

  # Add monthly hot water output request
  # TODO: Move this to reporting measure some day...
  outputVariable = OpenStudio::Model::OutputVariable.new('Water Use Equipment Hot Water Volume', model)
  outputVariable.setReportingFrequency('monthly')
  outputVariable.setKeyValue('*')

  # Translate model to IDF
  forward_translator = OpenStudio::EnergyPlus::ForwardTranslator.new
  forward_translator.setExcludeLCCObjects(true)
  model_idf = forward_translator.translateModel(model)
  report_ft_errors_warnings(forward_translator, rundir)

  # Apply reporting measure output requests
  apply_energyplus_output_requests(measures_dir, measures, runner, model, model_idf)

  # Write IDF to file
  File.open(File.join(rundir, 'in.idf'), 'w') { |f| f << model_idf.to_s }

  return if skip_simulation

  puts 'Running simulation...'

  # getEnergyPlusDirectory can be unreliable, using getOpenStudioCLI instead
  ep_path = File.absolute_path(File.join(OpenStudio.getOpenStudioCLI.to_s, '..', '..', 'EnergyPlus', 'energyplus'))
  command = "cd #{rundir} && #{ep_path} -w in.epw in.idf > stdout-energyplus"
  system(command, err: File::NULL)

  puts 'Processing output...'

  # Apply reporting measures
  runner.setLastEnergyPlusSqlFilePath(File.join(rundir, 'eplusout.sql'))
  success = apply_measures(measures_dir, measures, runner, model, true, 'OpenStudio::Measure::ReportingMeasure')
  report_measure_errors_warnings(runner, rundir, debug)

  if not success
    fail 'Processing output unsuccessful.'
  end

  # Map between HES resource_type and HES units
  units_map = { 'electric' => 'kWh',
                'natural_gas' => 'kBtu',
                'lpg' => 'kBtu',
                'fuel_oil' => 'kBtu',
                'cord_wood' => 'kBtu',
                'pellet_wood' => 'kBtu',
                'hot_water' => 'gallons' }

  # Map between reporting measure end use and HEScore [end_use, resource_type]
  output_map = {
    'Electricity: Heating' => ['heating', 'electric'],
    'Electricity: Heating Fans/Pumps' => ['heating', 'electric'],
    'Natural Gas: Heating' => ['heating', 'natural_gas'],
    'Propane: Heating' => ['heating', 'lpg'],
    'Fuel Oil: Heating' => ['heating', 'fuel_oil'],
    'Wood: Heating' => ['heating', 'cord_wood'],
    'Wood Pellets: Heating' => ['heating', 'pellet_wood'],
    'Electricity: Cooling' => ['cooling', 'electric'],
    'Electricity: Cooling Fans/Pumps' => ['cooling', 'electric'],
    'Electricity: Hot Water' => ['hot_water', 'electric'],
    'Natural Gas: Hot Water' => ['hot_water', 'natural_gas'],
    'Propane: Hot Water' => ['hot_water', 'lpg'],
    'Fuel Oil: Hot Water' => ['hot_water', 'fuel_oil'],
    'Electricity: Refrigerator' => ['large_appliance', 'electric'],
    'Electricity: Dishwasher' => ['large_appliance', 'electric'],
    'Electricity: Clothes Washer' => ['large_appliance', 'electric'],
    'Electricity: Clothes Dryer' => ['large_appliance', 'electric'],
    'Electricity: Range/Oven' => ['small_appliance', 'electric'],
    'Electricity: Television' => ['small_appliance', 'electric'],
    'Electricity: Plug Loads' => ['small_appliance', 'electric'],
    'Electricity: Lighting Interior' => ['lighting', 'electric'],
    'Electricity: Lighting Garage' => ['lighting', 'electric'],
    'Electricity: Lighting Exterior' => ['lighting', 'electric'],
    'Electricity: PV' => ['generation', 'electric'],
  }

  results = {}
  output_map.each do |ep_output, hes_output|
    results[hes_output] = []
  end
  row_index = {}
  units = nil
  timeseries_csv_path = File.join(rundir, 'results_timeseries.csv')
  CSV.foreach(timeseries_csv_path).with_index do |row, row_num|
    if row_num == 0 # Header
      output_map.each do |ep_output, hes_output|
        row_index[ep_output] = row.index(ep_output)
      end
    elsif row_num == 1 # Units
      units = row
    else # Data
      # Init for month
      results.keys.each do |k|
        results[k] << 0.0
      end
      # Add values
      output_map.each do |ep_output, hes_output|
        col = row_index[ep_output]
        results[hes_output][-1] += UnitConversions.convert(Float(row[col]), units[col], units_map[hes_output[1]])
      end
      # Make sure there aren't any end uses with positive values that aren't mapped to HES
      row.each_with_index do |val, col|
        next if col == 0 # Skip time column
        next if row_index.values.include? col

        fail "Missed energy (#{val}) in row=#{row_num}, col=#{col}." if Float(val) > 0
      end
    end
  end

  # Add hot water volume output
  # TODO: Move this to reporting measure some day...
  sql_path = File.join(rundir, 'eplusout.sql')
  sqlFile = OpenStudio::SqlFile.new(sql_path, false)
  hes_end_use = 'hot_water'
  hes_resource_type = 'hot_water'
  to_units = units_map[hes_resource_type]
  results[[hes_end_use, hes_resource_type]] = []
  for i in 1..12
    query = "SELECT SUM(VariableValue) FROM ReportVariableData WHERE ReportVariableDataDictionaryIndex IN (SELECT ReportVariableDataDictionaryIndex FROM ReportVariableDataDictionary WHERE VariableName='Water Use Equipment Hot Water Volume' AND ReportingFrequency='Monthly' AND VariableUnits='m3') AND TimeIndex='#{i}'"
    sql_result = sqlFile.execAndReturnFirstDouble(query).get
    results[[hes_end_use, hes_resource_type]] << UnitConversions.convert(sql_result, 'm^3', 'gal')
  end

  # Write results to JSON
  data = { 'end_use' => [] }
  results.each do |hes_key, values|
    hes_end_use, hes_resource_type = hes_key
    to_units = units_map[hes_resource_type]
    annual_value = values.inject(0, :+)
    next if annual_value <= 0.01

    values.each_with_index do |value, idx|
      end_use = { 'quantity' => value,
                  'period_type' => 'month',
                  'period_number' => (idx + 1).to_s,
                  'end_use' => hes_end_use,
                  'resource_type' => hes_resource_type,
                  'units' => to_units }
      data['end_use'] << end_use
    end
  end

  File.open(File.join(resultsdir, 'results.json'), 'w') do |f|
    f.write(data.to_s.gsub('=>', ':')) # Much faster than requiring JSON to use pretty_generate
  end
end

def report_measure_errors_warnings(runner, rundir, debug)
  # Report warnings/errors
  File.open(File.join(rundir, 'run.log'), 'w') do |f|
    if debug
      runner.result.stepInfo.each do |s|
        f << "Info: #{s}\n"
      end
    end
    runner.result.stepWarnings.each do |s|
      f << "Warning: #{s}\n"
    end
    runner.result.stepErrors.each do |s|
      f << "Error: #{s}\n"
    end
  end
end

def report_ft_errors_warnings(forward_translator, rundir)
  # Report warnings/errors
  File.open(File.join(rundir, 'run.log'), 'a') do |f|
    forward_translator.warnings.each do |s|
      f << "FT Warning: #{s.logMessage}\n"
    end
    forward_translator.errors.each do |s|
      f << "FT Error: #{s.logMessage}\n"
    end
  end
end

def download_epws
  weather_dir = File.join(File.dirname(__FILE__), '..', 'weather')

  num_epws_expected = File.readlines(File.join(weather_dir, 'data.csv')).size - 1
  num_epws_actual = Dir[File.join(weather_dir, '*.epw')].count
  num_cache_expcted = num_epws_expected
  num_cache_actual = Dir[File.join(weather_dir, '*-cache.csv')].count
  if (num_epws_actual == num_epws_expected) && (num_cache_actual == num_cache_expcted)
    puts 'Weather directory is already up-to-date.'
    puts "#{num_epws_actual} weather files are available in the weather directory."
    puts 'Completed.'
    exit!
  end

  require 'net/http'
  require 'tempfile'

  tmpfile = Tempfile.new('epw')

  url = URI.parse('https://data.nrel.gov/files/128/tmy3s-cache-csv.zip')
  http = Net::HTTP.new(url.host, url.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE

  params = { 'User-Agent' => 'curl/7.43.0', 'Accept-Encoding' => 'identity' }
  request = Net::HTTP::Get.new(url.path, params)
  request.content_type = 'application/zip, application/octet-stream'

  http.request request do |response|
    total = response.header['Content-Length'].to_i
    if total == 0
      fail 'Did not successfully download zip file.'
    end

    size = 0
    progress = 0
    open tmpfile, 'wb' do |io|
      response.read_body do |chunk|
        io.write chunk
        size += chunk.size
        new_progress = (size * 100) / total
        unless new_progress == progress
          puts 'Downloading %s (%3d%%) ' % [url.path, new_progress]
        end
        progress = new_progress
      end
    end
  end

  puts 'Extracting weather files...'
  unzip_file = OpenStudio::UnzipFile.new(tmpfile.path.to_s)
  unzip_file.extractAllFiles(OpenStudio::toPath(weather_dir))

  num_epws_actual = Dir[File.join(weather_dir, '*.epw')].count
  puts "#{num_epws_actual} weather files are available in the weather directory."
  puts 'Completed.'
  exit!
end

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: #{File.basename(__FILE__)} -x building.xml\n e.g., #{File.basename(__FILE__)} -x sample_files/valid.xml\n"

  opts.on('-x', '--xml <FILE>', 'HPXML file') do |t|
    options[:hpxml] = t
  end

  opts.on('-o', '--output-dir <DIR>', 'Output directory') do |t|
    options[:output_dir] = t
  end

  opts.on('-w', '--download-weather', 'Downloads all weather files') do |t|
    options[:epws] = t
  end

  options[:skip_simulation] = false
  opts.on('--skip-simulation', 'Skip the EnergyPlus simulation') do |t|
    options[:skip_simulation] = true
  end

  options[:debug] = false
  opts.on('-d', '--debug') do |t|
    options[:debug] = true
  end

  opts.on_tail('-h', '--help', 'Display help') do
    puts opts
    exit!
  end
end.parse!

if options[:epws]
  download_epws
end

if not options[:hpxml]
  fail "HPXML argument is required. Call #{File.basename(__FILE__)} -h for usage."
end

unless (Pathname.new options[:hpxml]).absolute?
  options[:hpxml] = File.expand_path(options[:hpxml])
end
unless File.exist?(options[:hpxml]) && options[:hpxml].downcase.end_with?('.xml')
  fail "'#{options[:hpxml]}' does not exist or is not an .xml file."
end

# Check for correct versions of OS
os_version = '2.9.1'
if OpenStudio.openStudioVersion != os_version
  fail "OpenStudio version #{os_version} is required."
end

if options[:output_dir].nil?
  options[:output_dir] = basedir # default
end
options[:output_dir] = File.expand_path(options[:output_dir])

unless Dir.exist?(options[:output_dir])
  FileUtils.mkdir_p(options[:output_dir])
end

# Create results dir
resultsdir = File.join(options[:output_dir], 'results')
rm_path(resultsdir)
Dir.mkdir(resultsdir)

# Run design
puts "HPXML: #{options[:hpxml]}"
design = 'HEScoreDesign'
rundir = get_rundir(options[:output_dir], design)
rm_path(rundir)
rundir = run_design(basedir, rundir, design, resultsdir, options[:hpxml], options[:debug], options[:skip_simulation])

puts "Completed in #{(Time.now - start_time).round(1)} seconds."
