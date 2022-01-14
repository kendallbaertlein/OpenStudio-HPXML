# frozen_string_literal: true

require_relative '../../HPXMLtoOpenStudio/resources/minitest_helper'
require_relative '../../HPXMLtoOpenStudio/resources/constants'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require_relative '../measure.rb'

class ReportUtilityBillsTest < MiniTest::Test
  def setup
    @args_hash = {}
    @args_hash['hpxml_path'] = '../workflow/sample_files/base.xml'
    @args_hash['electricity_bill_type'] = 'Simple'
    @args_hash['electricity_fixed_charge'] = 12.0
    @args_hash['electricity_marginal_rate'] = Constants.Auto
    @args_hash['natural_gas_fixed_charge'] = 8.0
    @args_hash['natural_gas_marginal_rate'] = Constants.Auto
    @args_hash['fuel_oil_marginal_rate'] = Constants.Auto
    @args_hash['propane_marginal_rate'] = Constants.Auto
    @args_hash['wood_cord_marginal_rate'] = Constants.Auto
    @args_hash['wood_pellets_marginal_rate'] = Constants.Auto
    @args_hash['coal_marginal_rate'] = Constants.Auto

    @expected_bills = {
      'Electricity: Fixed ($)' => 0.0,
      'Electricity: Marginal ($)' => 0.0,
      'Electricity: Total ($)' => 0.0,
      'Natural Gas: Fixed ($)' => 0.0,
      'Natural Gas: Marginal ($)' => 0.0,
      'Natural Gas: Total ($)' => 0.0,
      'Fuel Oil: Total ($)' => 0.0,
      'Propane: Total ($)' => 0.0,
      'Wood Cord: Total ($)' => 0.0,
      'Wood Pellets: Total ($)' => 0.0,
      'Coal: Total ($)' => 0.0
    }
  end

  def test_simple_calculations_auto_rates
    bills_csv = _test_measure(@args_hash)
    assert(File.exist?(bills_csv))
    @expected_bills['Electricity: Fixed ($)'] = 144.0
    @expected_bills['Electricity: Marginal ($)'] = 1046.85
    @expected_bills['Electricity: Total ($)'] = 1190.85
    @expected_bills['Natural Gas: Fixed ($)'] = 96.0
    @expected_bills['Natural Gas: Marginal ($)'] = 94.01
    @expected_bills['Natural Gas: Total ($)'] = 190.01
    actual_bills = get_actual_bills(bills_csv)
    assert_equal(@expected_bills, actual_bills)
  end

  def test_simple_calculations_specified_rates
    @args_hash['electricity_marginal_rate'] = '0.1'
    @args_hash['natural_gas_marginal_rate'] = '1.0'
    bills_csv = _test_measure(@args_hash)
    assert(File.exist?(bills_csv))
    @expected_bills['Electricity: Fixed ($)'] = 144.0
    @expected_bills['Electricity: Marginal ($)'] = 1025.04
    @expected_bills['Electricity: Total ($)'] = 1169.04
    @expected_bills['Natural Gas: Fixed ($)'] = 96.0
    @expected_bills['Natural Gas: Marginal ($)'] = 145.27
    @expected_bills['Natural Gas: Total ($)'] = 241.27
    actual_bills = get_actual_bills(bills_csv)
    assert_equal(@expected_bills, actual_bills)
  end

  def test_simple_calculations_fuel_oil
    @args_hash['hpxml_path'] = '../workflow/sample_files/base-hvac-furnace-oil-only.xml'
    bills_csv = _test_measure(@args_hash)
    assert(File.exist?(bills_csv))
    @expected_bills['Electricity: Fixed ($)'] = 144.0
    @expected_bills['Electricity: Marginal ($)'] = 922.31
    @expected_bills['Electricity: Total ($)'] = 1066.31
    @expected_bills['Fuel Oil: Total ($)'] = 281.66
    actual_bills = get_actual_bills(bills_csv)
    assert_equal(@expected_bills, actual_bills)
  end

  def test_simple_calculations_propane
    @args_hash['hpxml_path'] = '../workflow/sample_files/base-hvac-furnace-propane-only.xml'
    bills_csv = _test_measure(@args_hash)
    assert(File.exist?(bills_csv))
    @expected_bills['Electricity: Fixed ($)'] = 144.0
    @expected_bills['Electricity: Marginal ($)'] = 922.31
    @expected_bills['Electricity: Total ($)'] = 1066.31
    @expected_bills['Propane: Total ($)'] = 327.14
    actual_bills = get_actual_bills(bills_csv)
    assert_equal(@expected_bills, actual_bills)
  end

  def test_simple_calculations_wood_cord
    @args_hash['hpxml_path'] = '../workflow/sample_files/base-hvac-furnace-wood-only.xml'
    bills_csv = _test_measure(@args_hash)
    assert(File.exist?(bills_csv))
    @expected_bills['Electricity: Fixed ($)'] = 144.0
    @expected_bills['Electricity: Marginal ($)'] = 922.31
    @expected_bills['Electricity: Total ($)'] = 1066.31
    @expected_bills['Wood Cord: Total ($)'] = 1505.81
    actual_bills = get_actual_bills(bills_csv)
    assert_equal(@expected_bills, actual_bills)
  end

  def test_simple_calculations_wood_pellets
    @args_hash['hpxml_path'] = '../workflow/sample_files/base-hvac-stove-wood-pellets-only.xml'
    bills_csv = _test_measure(@args_hash)
    assert(File.exist?(bills_csv))
    @expected_bills['Electricity: Fixed ($)'] = 144.0
    @expected_bills['Electricity: Marginal ($)'] = 911.9
    @expected_bills['Electricity: Total ($)'] = 1055.9
    @expected_bills['Wood Pellets: Total ($)'] = 1426.89
    actual_bills = get_actual_bills(bills_csv)
    assert_equal(@expected_bills, actual_bills)
  end

  def test_simple_calculations_coal
    @args_hash['hpxml_path'] = '../workflow/sample_files/base-hvac-furnace-coal-only.xml'
    bills_csv = _test_measure(@args_hash)
    assert(File.exist?(bills_csv))
    @expected_bills['Electricity: Fixed ($)'] = 144.0
    @expected_bills['Electricity: Marginal ($)'] = 922.31
    @expected_bills['Electricity: Total ($)'] = 1066.31
    @expected_bills['Coal: Total ($)'] = 1505.81
    actual_bills = get_actual_bills(bills_csv)
    assert_equal(@expected_bills, actual_bills)
  end

  def get_actual_bills(bills_csv)
    actual_bills = {}
    File.readlines(bills_csv).each do |line|
      next if line.strip.empty?

      key, value = line.split(',').map { |x| x.strip }
      actual_bills[key] = Float(value)
    end
    return actual_bills
  end

  def _test_measure(args_hash)
    # Run measure via OSW
    require 'json'
    template_osw = File.join(File.dirname(__FILE__), '..', '..', 'workflow', 'template-report-utility-bills.osw')
    workflow = OpenStudio::WorkflowJSON.new(template_osw)
    json = JSON.parse(workflow.to_s)

    # Update measure args
    steps = OpenStudio::WorkflowStepVector.new
    found_args = []
    json['steps'].each do |json_step|
      step = OpenStudio::MeasureStep.new(json_step['measure_dir_name'])
      json_step['arguments'].each do |json_arg_name, json_arg_val|
        if args_hash.keys.include? json_arg_name
          # Override value
          found_args << json_arg_name
          json_arg_val = args_hash[json_arg_name]
        end
        step.setArgument(json_arg_name, json_arg_val)
      end
      steps.push(step)
    end
    workflow.setWorkflowSteps(steps)
    osw_path = File.join(File.dirname(template_osw), 'test.osw')
    workflow.saveAs(osw_path)
    assert_equal(args_hash.size, found_args.size)

    # Run OSW
    success = system("#{OpenStudio.getOpenStudioCLI} run -w #{osw_path}")
    assert_equal(true, success)

    # Cleanup
    File.delete(osw_path)

    bills_csv = File.join(File.dirname(template_osw), 'run', 'results_bills.csv')
    return bills_csv
  end
end
