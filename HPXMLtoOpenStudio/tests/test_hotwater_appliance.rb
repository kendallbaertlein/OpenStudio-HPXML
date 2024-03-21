# frozen_string_literal: true

require_relative '../resources/minitest_helper'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'fileutils'
require_relative '../measure.rb'
require_relative '../resources/util.rb'

class HPXMLtoOpenStudioHotWaterApplianceTest < Minitest::Test
  def sample_files_dir
    return File.join(File.dirname(__FILE__), '..', '..', 'workflow', 'sample_files')
  end

  def get_ee_kwh_per_year(model, name)
    kwh_yr = 0.0
    model.getElectricEquipments.each do |ee|
      next unless ee.endUseSubcategory.start_with? name

      hrs = Schedule.annual_equivalent_full_load_hrs(model.yearDescription.get.assumedYear, ee.schedule.get)
      kwh_yr += UnitConversions.convert(hrs * ee.designLevel.get * ee.multiplier * ee.space.get.multiplier, 'Wh', 'kWh')
    end
    return kwh_yr
  end

  def get_ee_fractions(model, name)
    sens_frac = []
    lat_frac = []
    model.getElectricEquipments.each do |ee|
      next unless ee.endUseSubcategory.start_with? name

      sens_frac << 1.0 - ee.electricEquipmentDefinition.fractionLost - ee.electricEquipmentDefinition.fractionLatent
      lat_frac << ee.electricEquipmentDefinition.fractionLatent
    end
    if sens_frac.empty?
      return []
    else
      return sens_frac.sum(0.0) / sens_frac.size, lat_frac.sum(0.0) / lat_frac.size
    end
  end

  def get_oe_kwh(model, name)
    kwh_yr = []
    model.getOtherEquipments.each do |oe|
      next unless oe.endUseSubcategory.start_with? name

      hrs = Schedule.annual_equivalent_full_load_hrs(model.yearDescription.get.assumedYear, oe.schedule.get)
      kwh_yr << UnitConversions.convert(hrs * oe.otherEquipmentDefinition.designLevel.get * oe.multiplier * oe.space.get.multiplier, 'Wh', 'kWh')
    end
    if kwh_yr.empty?
      return
    else
      return kwh_yr.sum(0.0)
    end
  end

  def get_oe_fuel(model, name)
    fuel = []
    model.getOtherEquipments.each do |oe|
      next unless oe.endUseSubcategory.start_with? name

      fuel << oe.fuelType
    end
    if fuel.empty?
      return
    elsif fuel.uniq.size != 1
      flunk 'different fuels'
    else
      return fuel[0]
    end
  end

  def get_oe_fractions(model, name)
    sens_frac = []
    lat_frac = []
    model.getOtherEquipments.each do |oe|
      next unless oe.endUseSubcategory.start_with? name

      sens_frac << 1.0 - oe.otherEquipmentDefinition.fractionLost - oe.otherEquipmentDefinition.fractionLatent
      lat_frac << oe.otherEquipmentDefinition.fractionLatent
    end
    if sens_frac.empty?
      return []
    else
      return sens_frac.sum(0.0) / sens_frac.size, lat_frac.sum(0.0) / lat_frac.size
    end
  end

  def get_wu_gpd(model, name)
    gpd = []
    model.getWaterUseEquipments.each do |wue|
      next unless wue.waterUseEquipmentDefinition.endUseSubcategory.start_with? name

      full_load_hrs = Schedule.annual_equivalent_full_load_hrs(model.yearDescription.get.assumedYear, wue.flowRateFractionSchedule.get)
      gpd << UnitConversions.convert(full_load_hrs * wue.waterUseEquipmentDefinition.peakFlowRate * wue.multiplier, 'm^3/s', 'gal/min') * 60.0 / 365.0
    end
    if gpd.empty?
      return
    else
      return gpd.sum(0.0)
    end
  end

  def test_base
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base.xml'))
    model, _hpxml, _hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    fixture_gpd = 43.71
    dist_gpd = 10.030
    cw_gpd = 3.7116
    dw_gpd = 2.7342
    assert_in_epsilon(cw_gpd, get_wu_gpd(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(dw_gpd, get_wu_gpd(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(fixture_gpd, get_wu_gpd(model, Constants.ObjectNameFixtures), 0.001)
    assert_in_epsilon(dist_gpd, get_wu_gpd(model, Constants.ObjectNameDistributionWaste), 0.001)

    # electric equipment
    cw_ee_kwh_yr = 107.059
    cw_sens_frac = 0.27
    cw_lat_frac = 0.03
    assert_in_epsilon(cw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(cw_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[0], 0.001)
    assert_in_epsilon(cw_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[1], 0.001)

    dw_ee_kwh_yr = 93.392
    dw_sens_frac = 0.3
    dw_lat_frac = 0.300
    assert_in_epsilon(dw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(dw_sens_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[0], 0.001)
    assert_in_epsilon(dw_lat_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[1], 0.001)

    cd_ee_kwh_yr = 443.317
    cd_sens_frac = 0.135
    cd_lat_frac = 0.015
    assert_in_epsilon(cd_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    rf_sens_frac = 1.0
    rf_lat_frac = 0.0
    assert_in_epsilon(rf_sens_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[0], 0.001)
    assert_in_epsilon(rf_lat_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[1], 0.001)

    cook_ee_kwh_yr = 448.0
    cook_sens_frac = 0.72
    cook_lat_frac = 0.080
    assert_in_epsilon(cook_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)

    # other equipment
    water_sens = -262.507
    water_lat = 266.358
    assert_in_epsilon(water_sens, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseSensible), 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[0], 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[1], 0.001)

    assert_in_epsilon(water_lat, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseLatent), 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[0], 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[1], 0.001)

    # mains temperature
    avg_tmains = 57.58
    assert_in_epsilon(avg_tmains, UnitConversions.convert(model.getSiteWaterMainsTemperature.temperatureSchedule.get.to_ScheduleInterval.get.timeSeries.averageValue, 'C', 'F'), 0.001)
  end

  def test_dhw_multiple
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-multiple.xml'))
    model, _hpxml, _hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    fixture_gpd = 15.30
    dist_gpd = 3.510
    cw_gpd = 1.2991
    dw_gpd = 0.9570
    assert_in_epsilon(fixture_gpd, get_wu_gpd(model, Constants.ObjectNameFixtures), 0.001)
    assert_in_epsilon(dist_gpd, get_wu_gpd(model, Constants.ObjectNameDistributionWaste), 0.001)
    assert_in_epsilon(cw_gpd, get_wu_gpd(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(dw_gpd, get_wu_gpd(model, Constants.ObjectNameDishwasher), 0.001)

    # electric equipment
    cw_ee_kwh_yr = 107.059
    cw_sens_frac = 0.27
    cw_lat_frac = 0.03
    assert_in_epsilon(cw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(cw_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[0], 0.001)
    assert_in_epsilon(cw_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[1], 0.001)

    dw_ee_kwh_yr = 93.392
    dw_sens_frac = 0.3
    dw_lat_frac = 0.300
    assert_in_epsilon(dw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(dw_sens_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[0], 0.001)
    assert_in_epsilon(dw_lat_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[1], 0.001)

    cd_ee_kwh_yr = 443.317
    cd_sens_frac = 0.135
    cd_lat_frac = 0.015
    assert_in_epsilon(cd_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    rf_sens_frac = 1.0
    rf_lat_frac = 0.0
    assert_in_epsilon(rf_sens_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[0], 0.001)
    assert_in_epsilon(rf_lat_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[1], 0.001)

    cook_ee_kwh_yr = 448.0
    cook_sens_frac = 0.72
    cook_lat_frac = 0.080
    assert_in_epsilon(cook_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)

    # other equipment
    water_sens = -262.507
    water_lat = 266.358
    assert_in_epsilon(water_sens, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseSensible), 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[0], 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[1], 0.001)

    assert_in_epsilon(water_lat, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseLatent), 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[0], 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[1], 0.001)
  end

  def test_dhw_shared_water_heater_recirc
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-bldgtype-mf-unit-shared-water-heater-recirc.xml'))
    model, _hpxml, hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    fixture_gpd = 43.71
    dist_gpd = 12.103
    cw_gpd = 3.7116
    dw_gpd = 2.7342
    assert_in_epsilon(cw_gpd, get_wu_gpd(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(dw_gpd, get_wu_gpd(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(fixture_gpd, get_wu_gpd(model, Constants.ObjectNameFixtures), 0.001)
    assert_in_epsilon(dist_gpd, get_wu_gpd(model, Constants.ObjectNameDistributionWaste), 0.001)

    # electric equipment
    cw_ee_kwh_yr = 107.059
    cw_sens_frac = 0.27
    cw_lat_frac = 0.03
    assert_in_epsilon(cw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(cw_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[0], 0.001)
    assert_in_epsilon(cw_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[1], 0.001)

    dw_ee_kwh_yr = 93.392
    dw_sens_frac = 0.3
    dw_lat_frac = 0.300
    assert_in_epsilon(dw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(dw_sens_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[0], 0.001)
    assert_in_epsilon(dw_lat_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[1], 0.001)

    cd_ee_kwh_yr = 443.317
    cd_sens_frac = 0.135
    cd_lat_frac = 0.015
    assert_in_epsilon(cd_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    rf_sens_frac = 1.0
    rf_lat_frac = 0.0
    assert_in_epsilon(rf_sens_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[0], 0.001)
    assert_in_epsilon(rf_lat_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[1], 0.001)

    cook_ee_kwh_yr = 448.0
    cook_sens_frac = 0.72
    cook_lat_frac = 0.080
    assert_in_epsilon(cook_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)

    # other equipment
    water_sens = -262.507
    water_lat = 266.358
    assert_in_epsilon(water_sens, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseSensible), 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[0], 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[1], 0.001)

    assert_in_epsilon(water_lat, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseLatent), 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[0], 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[1], 0.001)

    # recirc
    hot_water_distribution = hpxml_bldg.hot_water_distributions[0]
    pump_kwh_yr = 8.76 * hot_water_distribution.shared_recirculation_pump_power / hot_water_distribution.shared_recirculation_number_of_units_served
    assert_in_epsilon(pump_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameHotWaterRecircPump), 0.001)

    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-bldgtype-mf-unit-shared-water-heater-recirc-beds-0.xml'))
    model, _hpxml, hpxml_bldg = _test_measure(args_hash)

    # recirc
    hot_water_distribution = hpxml_bldg.hot_water_distributions[0]
    pump_kwh_yr = 8.76 * hot_water_distribution.shared_recirculation_pump_power / hot_water_distribution.shared_recirculation_number_of_units_served
    assert_in_epsilon(pump_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameHotWaterRecircPump), 0.001)
  end

  def test_dhw_shared_laundry
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-bldgtype-mf-unit-shared-laundry-room.xml'))
    model, _hpxml, _hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    fixture_gpd = 43.71
    dist_gpd = 12.103
    cw_gpd = 3.7116
    dw_gpd = 2.7342
    assert_in_epsilon(cw_gpd, get_wu_gpd(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(dw_gpd, get_wu_gpd(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(fixture_gpd, get_wu_gpd(model, Constants.ObjectNameFixtures), 0.001)
    assert_in_epsilon(dist_gpd, get_wu_gpd(model, Constants.ObjectNameDistributionWaste), 0.001)

    # electric equipment
    cw_ee_kwh_yr = 107.059
    cw_sens_frac = 0.0
    cw_lat_frac = 0.0
    assert_in_epsilon(cw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(cw_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[0], 0.001)
    assert_in_epsilon(cw_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[1], 0.001)

    dw_ee_kwh_yr = 93.392
    dw_sens_frac = 0.0
    dw_lat_frac = 0.0
    assert_in_epsilon(dw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(dw_sens_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[0], 0.001)
    assert_in_epsilon(dw_lat_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[1], 0.001)

    cd_ee_kwh_yr = 443.317
    cd_sens_frac = 0.0
    cd_lat_frac = 0.0
    assert_in_epsilon(cd_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    rf_sens_frac = 1.0
    rf_lat_frac = 0.0
    assert_in_epsilon(rf_sens_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[0], 0.001)
    assert_in_epsilon(rf_lat_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[1], 0.001)

    cook_ee_kwh_yr = 448.0
    cook_sens_frac = 0.72
    cook_lat_frac = 0.080
    assert_in_epsilon(cook_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)

    # other equipment
    water_sens = -262.507
    water_lat = 266.358
    assert_in_epsilon(water_sens, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseSensible), 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[0], 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[1], 0.001)

    assert_in_epsilon(water_lat, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseLatent), 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[0], 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[1], 0.001)
  end

  def test_dhw_low_flow_fixtures
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-low-flow-fixtures.xml'))
    model, _hpxml, _hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    fixture_gpd = 42.39
    dist_gpd = 9.7261
    assert_in_epsilon(fixture_gpd, get_wu_gpd(model, Constants.ObjectNameFixtures), 0.001)
    assert_in_epsilon(dist_gpd, get_wu_gpd(model, Constants.ObjectNameDistributionWaste), 0.001)
  end

  def test_dhw_dwhr
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-dwhr.xml'))
    model, _hpxml, _hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    fixture_gpd = 43.71
    dist_gpd = 10.030
    assert_in_epsilon(fixture_gpd, get_wu_gpd(model, Constants.ObjectNameFixtures), 0.001)
    assert_in_epsilon(dist_gpd, get_wu_gpd(model, Constants.ObjectNameDistributionWaste), 0.001)

    # mains temperature
    avg_tmains = 70.91
    assert_in_epsilon(avg_tmains, UnitConversions.convert(model.getSiteWaterMainsTemperature.temperatureSchedule.get.to_ScheduleInterval.get.timeSeries.averageValue, 'C', 'F'), 0.001)
  end

  def test_dhw_recirc_demand
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-recirc-demand.xml'))
    model, _hpxml, hpxml_bldg = _test_measure(args_hash)

    # Get HPXML values
    hot_water_distribution = hpxml_bldg.hot_water_distributions[0]
    pump_kwh_yr = 0.15 * hot_water_distribution.recirculation_pump_power
    assert_in_epsilon(pump_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameHotWaterRecircPump), 0.001)
  end

  def test_dhw_recirc_manual
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-recirc-manual.xml'))
    model, _hpxml, hpxml_bldg = _test_measure(args_hash)

    # Get HPXML values
    hot_water_distribution = hpxml_bldg.hot_water_distributions[0]
    pump_kwh_yr = 0.10 * hot_water_distribution.recirculation_pump_power
    assert_in_epsilon(pump_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameHotWaterRecircPump), 0.001)
  end

  def test_dhw_recirc_no_control
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-recirc-nocontrol.xml'))
    model, _hpxml, hpxml_bldg = _test_measure(args_hash)

    # Get HPXML values
    hot_water_distribution = hpxml_bldg.hot_water_distributions[0]
    pump_kwh_yr = 8.76 * hot_water_distribution.recirculation_pump_power
    assert_in_epsilon(pump_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameHotWaterRecircPump), 0.001)
  end

  def test_dhw_recirc_timer
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-recirc-timer.xml'))
    model, _hpxml, hpxml_bldg = _test_measure(args_hash)

    # Get HPXML values
    hot_water_distribution = hpxml_bldg.hot_water_distributions[0]
    pump_kwh_yr = 8.76 * hot_water_distribution.recirculation_pump_power
    assert_in_epsilon(pump_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameHotWaterRecircPump), 0.001)
  end

  def test_dhw_recirc_temp
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-recirc-temperature.xml'))
    model, _hpxml, hpxml_bldg = _test_measure(args_hash)

    # Get HPXML values
    hot_water_distribution = hpxml_bldg.hot_water_distributions[0]
    pump_kwh_yr = 1.46 * hot_water_distribution.recirculation_pump_power
    assert_in_epsilon(pump_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameHotWaterRecircPump), 0.001)
  end

  def test_appliances_none
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-appliances-none.xml'))
    model, _hpxml, _hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    assert_nil(get_wu_gpd(model, Constants.ObjectNameClothesWasher))
    assert_nil(get_wu_gpd(model, Constants.ObjectNameDishwasher))

    # electric equipment
    assert_equal(0.0, get_ee_kwh_per_year(model, Constants.ObjectNameClothesWasher))
    assert(get_ee_fractions(model, Constants.ObjectNameClothesWasher).empty?)

    assert_equal(0.0, get_ee_kwh_per_year(model, Constants.ObjectNameDishwasher))
    assert(get_ee_fractions(model, Constants.ObjectNameDishwasher).empty?)

    assert_equal(0.0, get_ee_kwh_per_year(model, Constants.ObjectNameClothesDryer))
    assert(get_ee_fractions(model, Constants.ObjectNameClothesDryer).empty?)

    assert_equal(0.0, get_ee_kwh_per_year(model, Constants.ObjectNameRefrigerator))
    assert(get_ee_fractions(model, Constants.ObjectNameRefrigerator).empty?)

    assert_equal(0.0, get_ee_kwh_per_year(model, Constants.ObjectNameCookingRange))
    assert(get_ee_fractions(model, Constants.ObjectNameCookingRange).empty?)

    # other equipment
    water_sens = -262.507
    water_lat = 266.358
    assert_in_epsilon(water_sens, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseSensible), 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[0], 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[1], 0.001)

    assert_in_epsilon(water_lat, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseLatent), 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[0], 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[1], 0.001)
  end

  def test_appliances_modified
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-appliances-modified.xml'))
    model, _hpxml, _hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    cw_gpd = 3.7116
    dw_gpd = 5.475
    assert_in_epsilon(cw_gpd, get_wu_gpd(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(dw_gpd, get_wu_gpd(model, Constants.ObjectNameDishwasher), 0.001)

    # electric equipment
    cw_ee_kwh_yr = 107.059
    cw_sens_frac = 0.27
    cw_lat_frac = 0.03
    assert_in_epsilon(cw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(cw_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[0], 0.001)
    assert_in_epsilon(cw_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[1], 0.001)

    dw_ee_kwh_yr = 186.6
    dw_sens_frac = 0.3
    dw_lat_frac = 0.300
    assert_in_epsilon(dw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(dw_sens_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[0], 0.001)
    assert_in_epsilon(dw_lat_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[1], 0.001)

    cd_ee_kwh_yr = 445.1052
    cd_sens_frac = 0.9
    cd_lat_frac = 0.1
    assert_in_epsilon(cd_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    rf_sens_frac = 1.0
    rf_lat_frac = 0.0
    assert_in_epsilon(rf_sens_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[0], 0.001)
    assert_in_epsilon(rf_lat_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[1], 0.001)

    cook_ee_kwh_yr = 448.0
    cook_sens_frac = 0.72
    cook_lat_frac = 0.080
    assert_in_epsilon(cook_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)

    # other equipment
    water_sens = -262.507
    water_lat = 266.358
    assert_in_epsilon(water_sens, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseSensible), 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[0], 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[1], 0.001)

    assert_in_epsilon(water_lat, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseLatent), 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[0], 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[1], 0.001)
  end

  def test_appliances_oil
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-appliances-oil.xml'))
    model, _hpxml, _hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    cw_gpd = 3.7116
    dw_gpd = 2.7342
    assert_in_epsilon(cw_gpd, get_wu_gpd(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(dw_gpd, get_wu_gpd(model, Constants.ObjectNameDishwasher), 0.001)

    # electric equipment
    cw_ee_kwh_yr = 107.059
    cw_sens_frac = 0.27
    cw_lat_frac = 0.03
    assert_in_epsilon(cw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(cw_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[0], 0.001)
    assert_in_epsilon(cw_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[1], 0.001)

    dw_ee_kwh_yr = 93.392
    dw_sens_frac = 0.3
    dw_lat_frac = 0.300
    assert_in_epsilon(dw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(dw_sens_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[0], 0.001)
    assert_in_epsilon(dw_lat_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[1], 0.001)

    cd_ee_kwh_yr = 39.646
    cd_sens_frac = 0.135
    cd_lat_frac = 0.015
    assert_in_epsilon(cd_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    rf_sens_frac = 1.0
    rf_lat_frac = 0.0
    assert_in_epsilon(rf_sens_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[0], 0.001)
    assert_in_epsilon(rf_lat_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[1], 0.001)

    cook_ee_kwh_yr = 30.70
    cook_sens_frac = 0.64
    cook_lat_frac = 0.16
    assert_in_epsilon(cook_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)

    # other equipment
    water_sens = -262.507
    water_lat = 266.358
    assert_in_epsilon(water_sens, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseSensible), 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[0], 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[1], 0.001)

    assert_in_epsilon(water_lat, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseLatent), 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[0], 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[1], 0.001)

    cd_fuel_kwh = UnitConversions.convert(17.972, 'therm', 'kWh')
    assert_in_epsilon(cd_fuel_kwh, get_oe_kwh(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_equal(EPlus::FuelTypeOil, get_oe_fuel(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_oe_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_oe_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    cook_fuel_kwh = UnitConversions.convert(30.70, 'therm', 'kWh')
    assert_in_epsilon(cook_fuel_kwh, get_oe_kwh(model, Constants.ObjectNameCookingRange), 0.001)
    assert_equal(EPlus::FuelTypeOil, get_oe_fuel(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_oe_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_oe_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)
  end

  def test_appliances_gas
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-appliances-gas.xml'))
    model, _hpxml, _hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    cw_gpd = 3.7116
    dw_gpd = 2.7342
    assert_in_epsilon(cw_gpd, get_wu_gpd(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(dw_gpd, get_wu_gpd(model, Constants.ObjectNameDishwasher), 0.001)

    # electric equipment
    cw_ee_kwh_yr = 107.059
    cw_sens_frac = 0.27
    cw_lat_frac = 0.03
    assert_in_epsilon(cw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(cw_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[0], 0.001)
    assert_in_epsilon(cw_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[1], 0.001)

    dw_ee_kwh_yr = 93.392
    dw_sens_frac = 0.3
    dw_lat_frac = 0.300
    assert_in_epsilon(dw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(dw_sens_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[0], 0.001)
    assert_in_epsilon(dw_lat_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[1], 0.001)

    cd_ee_kwh_yr = 39.646
    cd_sens_frac = 0.135
    cd_lat_frac = 0.015
    assert_in_epsilon(cd_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    rf_sens_frac = 1.0
    rf_lat_frac = 0.0
    assert_in_epsilon(rf_sens_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[0], 0.001)
    assert_in_epsilon(rf_lat_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[1], 0.001)

    cook_ee_kwh_yr = 30.70
    cook_sens_frac = 0.64
    cook_lat_frac = 0.16
    assert_in_epsilon(cook_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)

    # other equipment
    water_sens = -262.507
    water_lat = 266.358
    assert_in_epsilon(water_sens, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseSensible), 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[0], 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[1], 0.001)

    assert_in_epsilon(water_lat, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseLatent), 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[0], 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[1], 0.001)

    cd_fuel_kwh = UnitConversions.convert(17.972, 'therm', 'kWh')
    assert_in_epsilon(cd_fuel_kwh, get_oe_kwh(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_equal(EPlus::FuelTypeNaturalGas, get_oe_fuel(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_oe_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_oe_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    cook_fuel_kwh = UnitConversions.convert(30.70, 'therm', 'kWh')
    assert_in_epsilon(cook_fuel_kwh, get_oe_kwh(model, Constants.ObjectNameCookingRange), 0.001)
    assert_equal(EPlus::FuelTypeNaturalGas, get_oe_fuel(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_oe_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_oe_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)
  end

  def test_appliances_propane
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-appliances-propane.xml'))
    model, _hpxml, _hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    cw_gpd = 3.7116
    dw_gpd = 2.7342
    assert_in_epsilon(cw_gpd, get_wu_gpd(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(dw_gpd, get_wu_gpd(model, Constants.ObjectNameDishwasher), 0.001)

    # electric equipment
    cw_ee_kwh_yr = 107.059
    cw_sens_frac = 0.27
    cw_lat_frac = 0.03
    assert_in_epsilon(cw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(cw_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[0], 0.001)
    assert_in_epsilon(cw_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[1], 0.001)

    dw_ee_kwh_yr = 93.392
    dw_sens_frac = 0.3
    dw_lat_frac = 0.300
    assert_in_epsilon(dw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(dw_sens_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[0], 0.001)
    assert_in_epsilon(dw_lat_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[1], 0.001)

    cd_ee_kwh_yr = 39.646
    cd_sens_frac = 0.135
    cd_lat_frac = 0.015
    assert_in_epsilon(cd_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    rf_sens_frac = 1.0
    rf_lat_frac = 0.0
    assert_in_epsilon(rf_sens_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[0], 0.001)
    assert_in_epsilon(rf_lat_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[1], 0.001)

    cook_ee_kwh_yr = 30.70
    cook_sens_frac = 0.64
    cook_lat_frac = 0.16
    assert_in_epsilon(cook_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)

    # other equipment
    water_sens = -262.507
    water_lat = 266.358
    assert_in_epsilon(water_sens, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseSensible), 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[0], 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[1], 0.001)

    assert_in_epsilon(water_lat, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseLatent), 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[0], 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[1], 0.001)

    cd_fuel_kwh = UnitConversions.convert(17.972, 'therm', 'kWh')
    assert_in_epsilon(cd_fuel_kwh, get_oe_kwh(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_equal(EPlus::FuelTypePropane, get_oe_fuel(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_oe_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_oe_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    cook_fuel_kwh = UnitConversions.convert(30.70, 'therm', 'kWh')
    assert_in_epsilon(cook_fuel_kwh, get_oe_kwh(model, Constants.ObjectNameCookingRange), 0.001)
    assert_equal(EPlus::FuelTypePropane, get_oe_fuel(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_oe_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_oe_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)
  end

  def test_appliances_wood
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-appliances-wood.xml'))
    model, _hpxml, _hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    cw_gpd = 3.7116
    dw_gpd = 2.7342
    assert_in_epsilon(cw_gpd, get_wu_gpd(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(dw_gpd, get_wu_gpd(model, Constants.ObjectNameDishwasher), 0.001)

    # electric equipment
    cw_ee_kwh_yr = 107.059
    cw_sens_frac = 0.27
    cw_lat_frac = 0.03
    assert_in_epsilon(cw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(cw_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[0], 0.001)
    assert_in_epsilon(cw_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[1], 0.001)

    dw_ee_kwh_yr = 93.392
    dw_sens_frac = 0.3
    dw_lat_frac = 0.300
    assert_in_epsilon(dw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(dw_sens_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[0], 0.001)
    assert_in_epsilon(dw_lat_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[1], 0.001)

    cd_ee_kwh_yr = 39.646
    cd_sens_frac = 0.135
    cd_lat_frac = 0.015
    assert_in_epsilon(cd_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    rf_sens_frac = 1.0
    rf_lat_frac = 0.0
    assert_in_epsilon(rf_sens_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[0], 0.001)
    assert_in_epsilon(rf_lat_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[1], 0.001)

    cook_ee_kwh_yr = 30.70
    cook_sens_frac = 0.64
    cook_lat_frac = 0.16
    assert_in_epsilon(cook_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)

    # other equipment
    water_sens = -262.507
    water_lat = 266.358
    assert_in_epsilon(water_sens, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseSensible), 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[0], 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[1], 0.001)

    assert_in_epsilon(water_lat, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseLatent), 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[0], 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[1], 0.001)

    cd_fuel_kwh = UnitConversions.convert(17.972, 'therm', 'kWh')
    assert_in_epsilon(cd_fuel_kwh, get_oe_kwh(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_equal(EPlus::FuelTypeWoodCord, get_oe_fuel(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_oe_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_oe_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    cook_fuel_kwh = UnitConversions.convert(30.70, 'therm', 'kWh')
    assert_in_epsilon(cook_fuel_kwh, get_oe_kwh(model, Constants.ObjectNameCookingRange), 0.001)
    assert_equal(EPlus::FuelTypeWoodCord, get_oe_fuel(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_oe_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_oe_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)
  end

  def test_appliances_coal
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-appliances-coal.xml'))
    model, _hpxml, _hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    cw_gpd = 3.7116
    dw_gpd = 2.7342
    assert_in_epsilon(cw_gpd, get_wu_gpd(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(dw_gpd, get_wu_gpd(model, Constants.ObjectNameDishwasher), 0.001)

    # electric equipment
    cw_ee_kwh_yr = 107.059
    cw_sens_frac = 0.27
    cw_lat_frac = 0.03
    assert_in_epsilon(cw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(cw_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[0], 0.001)
    assert_in_epsilon(cw_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[1], 0.001)

    dw_ee_kwh_yr = 93.392
    dw_sens_frac = 0.3
    dw_lat_frac = 0.300
    assert_in_epsilon(dw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(dw_sens_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[0], 0.001)
    assert_in_epsilon(dw_lat_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[1], 0.001)

    cd_ee_kwh_yr = 39.646
    cd_sens_frac = 0.135
    cd_lat_frac = 0.015
    assert_in_epsilon(cd_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    rf_sens_frac = 1.0
    rf_lat_frac = 0.0
    assert_in_epsilon(rf_sens_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[0], 0.001)
    assert_in_epsilon(rf_lat_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[1], 0.001)

    cook_ee_kwh_yr = 30.70
    cook_sens_frac = 0.64
    cook_lat_frac = 0.16
    assert_in_epsilon(cook_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)

    # other equipment
    water_sens = -262.507
    water_lat = 266.358
    assert_in_epsilon(water_sens, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseSensible), 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[0], 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[1], 0.001)

    assert_in_epsilon(water_lat, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseLatent), 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[0], 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[1], 0.001)

    cd_fuel_kwh = UnitConversions.convert(17.972, 'therm', 'kWh')
    assert_in_epsilon(cd_fuel_kwh, get_oe_kwh(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_equal(EPlus::FuelTypeCoal, get_oe_fuel(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_oe_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_oe_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    cook_fuel_kwh = UnitConversions.convert(30.70, 'therm', 'kWh')
    assert_in_epsilon(cook_fuel_kwh, get_oe_kwh(model, Constants.ObjectNameCookingRange), 0.001)
    assert_equal(EPlus::FuelTypeCoal, get_oe_fuel(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_oe_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_oe_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)
  end

  def test_usage_multiplier
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-misc-usage-multiplier.xml'))
    model, _hpxml, _hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    fixture_gpd = 43.71 * 0.9
    dist_gpd = 10.030 * 0.9
    cw_gpd = 3.7116 * 0.9
    dw_gpd = 2.7342 * 0.9
    assert_in_epsilon(cw_gpd, get_wu_gpd(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(dw_gpd, get_wu_gpd(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(fixture_gpd, get_wu_gpd(model, Constants.ObjectNameFixtures), 0.001)
    assert_in_epsilon(dist_gpd, get_wu_gpd(model, Constants.ObjectNameDistributionWaste), 0.001)

    # electric equipment
    cw_ee_kwh_yr = 107.059 * 0.9
    cw_sens_frac = 0.27
    cw_lat_frac = 0.03
    assert_in_epsilon(cw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(cw_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[0], 0.001)
    assert_in_epsilon(cw_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[1], 0.001)

    dw_ee_kwh_yr = 93.392 * 0.9
    dw_sens_frac = 0.3
    dw_lat_frac = 0.300
    assert_in_epsilon(dw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(dw_sens_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[0], 0.001)
    assert_in_epsilon(dw_lat_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[1], 0.001)

    cd_ee_kwh_yr = 443.317 * 0.9
    cd_sens_frac = 0.135
    cd_lat_frac = 0.015
    assert_in_epsilon(cd_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    rf_sens_frac = 1.0
    rf_lat_frac = 0.0
    assert_in_epsilon(rf_sens_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[0], 0.001)
    assert_in_epsilon(rf_lat_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[1], 0.001)

    cook_ee_kwh_yr = 448.0 * 0.9
    cook_sens_frac = 0.72
    cook_lat_frac = 0.080
    assert_in_epsilon(cook_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)

    # other equipment
    water_sens = -262.507 * 0.9
    water_lat = 266.358 * 0.9
    assert_in_epsilon(water_sens, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseSensible), 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[0], 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[1], 0.001)

    assert_in_epsilon(water_lat, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseLatent), 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[0], 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[1], 0.001)
  end

  def test_operational
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-residents-1.xml'))
    model, _hpxml, _hpxml_bldg = _test_measure(args_hash)

    # water use equipment peak flows
    fixture_gpd = 16.46
    dist_gpd = 3.261
    cw_gpd = 2.131
    dw_gpd = 1.3599
    assert_in_epsilon(cw_gpd, get_wu_gpd(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(dw_gpd, get_wu_gpd(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(fixture_gpd, get_wu_gpd(model, Constants.ObjectNameFixtures), 0.001)
    assert_in_epsilon(dist_gpd, get_wu_gpd(model, Constants.ObjectNameDistributionWaste), 0.001)

    # electric equipment
    cw_ee_kwh_yr = 61.4635
    cw_sens_frac = 0.27
    cw_lat_frac = 0.03
    assert_in_epsilon(cw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesWasher), 0.001)
    assert_in_epsilon(cw_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[0], 0.001)
    assert_in_epsilon(cw_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesWasher)[1], 0.001)

    dw_ee_kwh_yr = 46.450
    dw_sens_frac = 0.3
    dw_lat_frac = 0.300
    assert_in_epsilon(dw_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameDishwasher), 0.001)
    assert_in_epsilon(dw_sens_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[0], 0.001)
    assert_in_epsilon(dw_lat_frac, get_ee_fractions(model, Constants.ObjectNameDishwasher)[1], 0.001)

    cd_ee_kwh_yr = 254.4948
    cd_sens_frac = 0.135
    cd_lat_frac = 0.015
    assert_in_epsilon(cd_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameClothesDryer), 0.001)
    assert_in_epsilon(cd_sens_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[0], 0.001)
    assert_in_epsilon(cd_lat_frac, get_ee_fractions(model, Constants.ObjectNameClothesDryer)[1], 0.001)

    rf_sens_frac = 1.0
    rf_lat_frac = 0.0
    assert_in_epsilon(rf_sens_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[0], 0.001)
    assert_in_epsilon(rf_lat_frac, get_ee_fractions(model, Constants.ObjectNameRefrigerator)[1], 0.001)

    cook_ee_kwh_yr = 339.4481
    cook_sens_frac = 0.72
    cook_lat_frac = 0.080
    assert_in_epsilon(cook_ee_kwh_yr, get_ee_kwh_per_year(model, Constants.ObjectNameCookingRange), 0.001)
    assert_in_epsilon(cook_sens_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[0], 0.001)
    assert_in_epsilon(cook_lat_frac, get_ee_fractions(model, Constants.ObjectNameCookingRange)[1], 0.001)

    # other equipment
    water_sens = -140.879
    water_lat = 142.945
    assert_in_epsilon(water_sens, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseSensible), 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[0], 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseSensible)[1], 0.001)

    assert_in_epsilon(water_lat, get_oe_kwh(model, Constants.ObjectNameGeneralWaterUseLatent), 0.001)
    assert_in_epsilon(0.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[0], 0.001)
    assert_in_epsilon(1.0, get_oe_fractions(model, Constants.ObjectNameGeneralWaterUseLatent)[1], 0.001)
  end

  def _test_measure(args_hash)
    # create an instance of the measure
    measure = HPXMLtoOpenStudio.new

    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    model = OpenStudio::Model::Model.new

    # get arguments
    args_hash['output_dir'] = File.dirname(__FILE__)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      if args_hash.has_key?(arg.name)
        assert(temp_arg_var.setValue(args_hash[arg.name]))
      end
      argument_map[arg.name] = temp_arg_var
    end

    # run the measure
    measure.run(model, runner, argument_map)
    result = runner.result

    # show the output
    show_output(result) unless result.value.valueName == 'Success'

    # assert that it ran correctly
    assert_equal('Success', result.value.valueName)

    hpxml = HPXML.new(hpxml_path: args_hash['hpxml_path'])

    File.delete(File.join(File.dirname(__FILE__), 'in.xml'))

    return model, hpxml, hpxml.buildings[0]
  end
end
