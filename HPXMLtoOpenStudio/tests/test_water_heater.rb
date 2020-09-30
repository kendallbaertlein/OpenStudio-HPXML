# frozen_string_literal: true

require_relative '../resources/minitest_helper'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'minitest/autorun'
require 'fileutils'
require_relative '../measure.rb'
require_relative '../resources/util.rb'
require_relative '../resources/waterheater.rb'

class HPXMLtoOpenStudioWaterHeaterTest < MiniTest::Test
  def sample_files_dir
    return File.join(File.dirname(__FILE__), '..', '..', 'workflow', 'sample_files')
  end

  def test_tank_gas
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-tank-gas.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.95, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(7.88, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    ther_eff = 0.773
    loc = water_heating_system.location

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size)
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)
  end

  def test_tank_oil
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-tank-oil.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.95, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(7.88, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    ther_eff = 0.773
    loc = water_heating_system.location

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size)
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)
  end

  def test_tank_wood
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-tank-wood.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.95, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(7.88, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    ther_eff = 0.773
    loc = water_heating_system.location

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size)
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)
  end

  def test_tank_coal
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-tank-coal.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.95, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(7.88, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    ther_eff = 0.773
    loc = water_heating_system.location

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size)
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)
  end

  def test_tank_electric
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.9, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(1.335, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    ther_eff = 1.0
    loc = water_heating_system.location

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size)
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)
  end

  def test_tankless
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-tankless-electric.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(1.0, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(100000000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = 0.0
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C')
    ther_eff = 0.9108
    loc = water_heating_system.location

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size)
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)
  end

  def test_uef
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-uef.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.9, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(1.327, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    ther_eff = 1.0
    loc = water_heating_system.location

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size)
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)
  end

  def test_tank_outside
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-tank-gas-outside.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.95, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(7.88, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    ther_eff = 0.773

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size)
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal('Outdoors', wh.ambientTemperatureIndicator)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)
  end

  def test_dsh_1_speed
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-desuperheater.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.9, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(1.335, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    loc = water_heating_system.location
    ther_eff = 1.0

    # Check water heater
    assert_equal(2, model.getWaterHeaterMixeds.size) # preheat tank + water heater
    wh = model.getWaterHeaterMixeds.select { |wh| (not wh.name.get.include? 'storage tank') }[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)
    # Check desuperheater
    assert_equal(1, model.getCoilWaterHeatingDesuperheaters.size)
    preheat_tank = model.getWaterHeaterMixeds.select { |wh| wh.name.get.include? 'storage tank' }[0]
    dsh_coil = model.getCoilWaterHeatingDesuperheaters[0]
    assert_equal(true, dsh_coil.heatingSource.get.to_CoilCoolingDXSingleSpeed.is_initialized)
    assert_equal(preheat_tank, dsh_coil.heatRejectionTarget.get.to_WaterHeaterMixed.get)
  end

  def test_dsh_var_speed
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-desuperheater-var-speed.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.9, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(1.335, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    loc = water_heating_system.location
    ther_eff = 1.0

    # Check water heater
    assert_equal(2, model.getWaterHeaterMixeds.size) # preheat tank + water heater
    wh = model.getWaterHeaterMixeds.select { |wh| (not wh.name.get.include? 'storage tank') }[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)
    # Check desuperheater
    assert_equal(1, model.getCoilWaterHeatingDesuperheaters.size)
    preheat_tank = model.getWaterHeaterMixeds.select { |wh| wh.name.get.include? 'storage tank' }[0]
    dsh_coil = model.getCoilWaterHeatingDesuperheaters[0]
    assert_equal(true, dsh_coil.heatingSource.get.to_CoilCoolingDXMultiSpeed.is_initialized)
    assert_equal(preheat_tank, dsh_coil.heatRejectionTarget.get.to_WaterHeaterMixed.get)
  end

  def test_dsh_gshp
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-desuperheater-gshp.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.9, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(1.335, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    loc = water_heating_system.location
    ther_eff = 1.0

    # Check water heater
    assert_equal(2, model.getWaterHeaterMixeds.size) # preheat tank + water heater
    wh = model.getWaterHeaterMixeds.select { |wh| (not wh.name.get.include? 'storage tank') }[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)
    # Check desuperheater
    assert_equal(1, model.getCoilWaterHeatingDesuperheaters.size)
    preheat_tank = model.getWaterHeaterMixeds.select { |wh| wh.name.get.include? 'storage tank' }[0]
    dsh_coil = model.getCoilWaterHeatingDesuperheaters[0]
    assert_equal(true, dsh_coil.heatingSource.get.to_CoilCoolingWaterToAirHeatPumpEquationFit.is_initialized)
    assert_equal(preheat_tank, dsh_coil.heatRejectionTarget.get.to_WaterHeaterMixed.get)
  end

  def test_solar_direct_evacuated_tube
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-solar-direct-evacuated-tube.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]
    solar_thermal_system = hpxml.solar_thermal_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.9, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(1.335, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    loc = water_heating_system.location
    hx_eff = 1.0

    collector_area = UnitConversions.convert(solar_thermal_system.collector_area, 'ft^2', 'm^2')
    ther_eff = 1.0
    iam_coeff2 = 0.3023
    iam_coeff3 = -0.3057
    collector_coeff_2 = -UnitConversions.convert(solar_thermal_system.collector_frul, 'Btu/(hr*ft^2*F)', 'W/(m^2*K)')
    storage_tank_volume = 0.2271
    storage_tank_height = 1.3755
    storage_tank_u = 0.0
    pump_power = 0.8 * solar_thermal_system.collector_area

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size) # preheat tank + water heater
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)

    # Check solar thermal system
    assert_equal(1, model.getSolarCollectorFlatPlateWaters.size)
    assert_equal(1, model.getWaterHeaterStratifieds.size)
    preheat_tank = model.getWaterHeaterStratifieds[0]
    assert_in_epsilon(storage_tank_volume, preheat_tank.tankVolume.get, 0.001)
    assert_in_epsilon(storage_tank_height, preheat_tank.tankHeight.get, 0.001)
    assert_in_epsilon(hx_eff, preheat_tank.sourceSideEffectiveness, 0.001)
    assert_in_epsilon(storage_tank_u, preheat_tank.uniformSkinLossCoefficientperUnitAreatoAmbientTemperature.get, 0.001)

    collector = model.getSolarCollectorFlatPlateWaters[0]
    collector_performance = collector.solarCollectorPerformance
    assert_in_epsilon(collector_area, collector_performance.grossArea, 0.001)
    assert_in_epsilon(solar_thermal_system.collector_frta, collector_performance.coefficient1ofEfficiencyEquation, 0.001)
    assert_in_epsilon(collector_coeff_2, collector_performance.coefficient2ofEfficiencyEquation, 0.001)
    assert_in_epsilon(-iam_coeff2, collector_performance.coefficient2ofIncidentAngleModifier.get, 0.001)
    assert_in_epsilon(iam_coeff3, collector_performance.coefficient3ofIncidentAngleModifier.get, 0.001)

    collector_attached_to_tank = false
    loop = nil
    model.getPlantLoops.each do |plant_loop|
      next if plant_loop.supplyComponents.select { |comp| comp == collector }.empty?
      next if plant_loop.demandComponents.select { |comp| comp == preheat_tank }.empty?

      collector_attached_to_tank = true
      assert_equal(plant_loop.fluidType, 'Water')
      loop = plant_loop
    end
    pump = loop.supplyComponents.select { |comp| comp.to_PumpConstantSpeed.is_initialized }[0]
    assert_equal(pump_power, pump.to_PumpConstantSpeed.get.ratedPowerConsumption.get)
    assert_equal(collector_attached_to_tank, true)
  end

  def test_solar_direct_flat_plate
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-solar-direct-flat-plate.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]
    solar_thermal_system = hpxml.solar_thermal_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.9, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(1.335, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    loc = water_heating_system.location
    hx_eff = 1.0

    collector_area = UnitConversions.convert(solar_thermal_system.collector_area, 'ft^2', 'm^2')
    ther_eff = 1.0
    iam_coeff2 = 0.1
    iam_coeff3 = 0
    collector_coeff_2 = -UnitConversions.convert(solar_thermal_system.collector_frul, 'Btu/(hr*ft^2*F)', 'W/(m^2*K)')
    storage_tank_volume = 0.2271
    storage_tank_height = 1.3755
    storage_tank_u = 0.0
    pump_power = 0.8 * solar_thermal_system.collector_area

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size) # preheat tank + water heater
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)

    # Check solar thermal system
    assert_equal(1, model.getSolarCollectorFlatPlateWaters.size)
    assert_equal(1, model.getWaterHeaterStratifieds.size)
    preheat_tank = model.getWaterHeaterStratifieds[0]
    assert_in_epsilon(storage_tank_volume, preheat_tank.tankVolume.get, 0.001)
    assert_in_epsilon(storage_tank_height, preheat_tank.tankHeight.get, 0.001)
    assert_in_epsilon(hx_eff, preheat_tank.sourceSideEffectiveness, 0.001)
    assert_in_epsilon(storage_tank_u, preheat_tank.uniformSkinLossCoefficientperUnitAreatoAmbientTemperature.get, 0.001)

    collector = model.getSolarCollectorFlatPlateWaters[0]
    collector_performance = collector.solarCollectorPerformance
    assert_in_epsilon(collector_area, collector_performance.grossArea, 0.001)
    assert_in_epsilon(solar_thermal_system.collector_frta, collector_performance.coefficient1ofEfficiencyEquation, 0.001)
    assert_in_epsilon(collector_coeff_2, collector_performance.coefficient2ofEfficiencyEquation, 0.001)
    assert_in_epsilon(-iam_coeff2, collector_performance.coefficient2ofIncidentAngleModifier.get, 0.001)
    assert_in_epsilon(iam_coeff3, collector_performance.coefficient3ofIncidentAngleModifier.get, 0.001)

    collector_attached_to_tank = false
    loop = nil
    model.getPlantLoops.each do |plant_loop|
      next if plant_loop.supplyComponents.select { |comp| comp == collector }.empty?
      next if plant_loop.demandComponents.select { |comp| comp == preheat_tank }.empty?

      collector_attached_to_tank = true
      assert_equal(plant_loop.fluidType, 'Water')
      loop = plant_loop
    end
    pump = loop.supplyComponents.select { |comp| comp.to_PumpConstantSpeed.is_initialized }[0]
    assert_equal(pump_power, pump.to_PumpConstantSpeed.get.ratedPowerConsumption.get)
    assert_equal(collector_attached_to_tank, true)
  end

  def test_solar_indirect_flat_plate
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-solar-indirect-flat-plate.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]
    solar_thermal_system = hpxml.solar_thermal_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.9, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(1.335, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    loc = water_heating_system.location
    hx_eff = 0.7

    collector_area = UnitConversions.convert(solar_thermal_system.collector_area, 'ft^2', 'm^2')
    ther_eff = 1.0
    iam_coeff2 = 0.1
    iam_coeff3 = 0
    collector_coeff_2 = -UnitConversions.convert(solar_thermal_system.collector_frul, 'Btu/(hr*ft^2*F)', 'W/(m^2*K)')
    storage_tank_volume = UnitConversions.convert(solar_thermal_system.storage_volume, 'gal', 'm^3')
    storage_tank_height = UnitConversions.convert(4.513, 'ft', 'm')
    storage_tank_u = UnitConversions.convert(0.1, 'Btu/(hr*ft^2*F)', 'W/(m^2*K)')
    pump_power = 0.8 * solar_thermal_system.collector_area

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size) # preheat tank + water heater
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)

    # Check solar thermal system
    assert_equal(1, model.getSolarCollectorFlatPlateWaters.size)
    assert_equal(1, model.getWaterHeaterStratifieds.size)
    preheat_tank = model.getWaterHeaterStratifieds[0]
    assert_in_epsilon(storage_tank_volume, preheat_tank.tankVolume.get, 0.001)
    assert_in_epsilon(storage_tank_height, preheat_tank.tankHeight.get, 0.001)
    assert_in_epsilon(hx_eff, preheat_tank.sourceSideEffectiveness, 0.001)
    assert_in_epsilon(storage_tank_u, preheat_tank.uniformSkinLossCoefficientperUnitAreatoAmbientTemperature.get, 0.001)

    collector = model.getSolarCollectorFlatPlateWaters[0]
    collector_performance = collector.solarCollectorPerformance
    assert_in_epsilon(collector_area, collector_performance.grossArea, 0.001)
    assert_in_epsilon(solar_thermal_system.collector_frta, collector_performance.coefficient1ofEfficiencyEquation, 0.001)
    assert_in_epsilon(collector_coeff_2, collector_performance.coefficient2ofEfficiencyEquation, 0.001)
    assert_in_epsilon(-iam_coeff2, collector_performance.coefficient2ofIncidentAngleModifier.get, 0.001)
    assert_in_epsilon(iam_coeff3, collector_performance.coefficient3ofIncidentAngleModifier.get, 0.001)

    collector_attached_to_tank = false
    loop = nil
    model.getPlantLoops.each do |plant_loop|
      next if plant_loop.supplyComponents.select { |comp| comp == collector }.empty?
      next if plant_loop.demandComponents.select { |comp| comp == preheat_tank }.empty?

      collector_attached_to_tank = true
      assert_equal(plant_loop.fluidType, 'PropyleneGlycol')
      loop = plant_loop
    end
    pump = loop.supplyComponents.select { |comp| comp.to_PumpConstantSpeed.is_initialized }[0]
    assert_equal(pump_power, pump.to_PumpConstantSpeed.get.ratedPowerConsumption.get)
    assert_equal(collector_attached_to_tank, true)
  end

  def test_solar_thermosyphon_flat_plate
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-solar-thermosyphon-flat-plate.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]
    solar_thermal_system = hpxml.solar_thermal_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.9, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(1.335, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    loc = water_heating_system.location
    hx_eff = 1.0

    collector_area = UnitConversions.convert(solar_thermal_system.collector_area, 'ft^2', 'm^2')
    ther_eff = 1.0
    iam_coeff2 = 0.1
    iam_coeff3 = 0
    collector_coeff_2 = -UnitConversions.convert(solar_thermal_system.collector_frul, 'Btu/(hr*ft^2*F)', 'W/(m^2*K)')
    storage_tank_volume = 0.2271
    storage_tank_height = 1.3755
    storage_tank_u = 0.0
    pump_power = 0.0

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size) # preheat tank + water heater
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)

    # Check solar thermal system
    assert_equal(1, model.getSolarCollectorFlatPlateWaters.size)
    assert_equal(1, model.getWaterHeaterStratifieds.size)
    preheat_tank = model.getWaterHeaterStratifieds[0]
    assert_in_epsilon(storage_tank_volume, preheat_tank.tankVolume.get, 0.001)
    assert_in_epsilon(storage_tank_height, preheat_tank.tankHeight.get, 0.001)
    assert_in_epsilon(hx_eff, preheat_tank.sourceSideEffectiveness, 0.001)
    assert_in_epsilon(storage_tank_u, preheat_tank.uniformSkinLossCoefficientperUnitAreatoAmbientTemperature.get, 0.001)

    collector = model.getSolarCollectorFlatPlateWaters[0]
    collector_performance = collector.solarCollectorPerformance
    assert_in_epsilon(collector_area, collector_performance.grossArea, 0.001)
    assert_in_epsilon(solar_thermal_system.collector_frta, collector_performance.coefficient1ofEfficiencyEquation, 0.001)
    assert_in_epsilon(collector_coeff_2, collector_performance.coefficient2ofEfficiencyEquation, 0.001)
    assert_in_epsilon(-iam_coeff2, collector_performance.coefficient2ofIncidentAngleModifier.get, 0.001)
    assert_in_epsilon(iam_coeff3, collector_performance.coefficient3ofIncidentAngleModifier.get, 0.001)

    collector_attached_to_tank = false
    loop = nil
    model.getPlantLoops.each do |plant_loop|
      next if plant_loop.supplyComponents.select { |comp| comp == collector }.empty?
      next if plant_loop.demandComponents.select { |comp| comp == preheat_tank }.empty?

      collector_attached_to_tank = true
      assert_equal(plant_loop.fluidType, 'Water')
      loop = plant_loop
    end
    pump = loop.supplyComponents.select { |comp| comp.to_PumpConstantSpeed.is_initialized }[0]
    assert_equal(pump_power, pump.to_PumpConstantSpeed.get.ratedPowerConsumption.get)
    assert_equal(collector_attached_to_tank, true)
  end

  def test_solar_direct_ics
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-solar-direct-ics.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]
    solar_thermal_system = hpxml.solar_thermal_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.9, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(1.335, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    loc = water_heating_system.location
    hx_eff = 1.0

    collector_area = UnitConversions.convert(solar_thermal_system.collector_area, 'ft^2', 'm^2')
    collector_storage_volume = UnitConversions.convert(solar_thermal_system.storage_volume, 'gal', 'm^3')
    ther_eff = 1.0
    storage_tank_volume = 0.2271
    storage_tank_height = 1.3755
    storage_tank_u = 0.0
    pump_power = 0.8 * solar_thermal_system.collector_area

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size) # preheat tank + water heater
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)

    # Check solar thermal system
    assert_equal(1, model.getSolarCollectorIntegralCollectorStorages.size)
    assert_equal(1, model.getWaterHeaterStratifieds.size)
    preheat_tank = model.getWaterHeaterStratifieds[0]
    assert_in_epsilon(storage_tank_volume, preheat_tank.tankVolume.get, 0.001)
    assert_in_epsilon(storage_tank_height, preheat_tank.tankHeight.get, 0.001)
    assert_in_epsilon(hx_eff, preheat_tank.sourceSideEffectiveness, 0.001)
    assert_in_epsilon(storage_tank_u, preheat_tank.uniformSkinLossCoefficientperUnitAreatoAmbientTemperature.get, 0.001)

    collector = model.getSolarCollectorIntegralCollectorStorages[0]
    collector_performance = collector.solarCollectorPerformance
    assert_in_epsilon(collector_area, collector_performance.grossArea, 0.001)
    assert_in_epsilon(collector_storage_volume, collector_performance.collectorWaterVolume, 0.001)

    collector_attached_to_tank = false
    loop = nil
    model.getPlantLoops.each do |plant_loop|
      next if plant_loop.supplyComponents.select { |comp| comp == collector }.empty?
      next if plant_loop.demandComponents.select { |comp| comp == preheat_tank }.empty?

      collector_attached_to_tank = true
      assert_equal(plant_loop.fluidType, 'Water')
      loop = plant_loop
    end
    pump = loop.supplyComponents.select { |comp| comp.to_PumpConstantSpeed.is_initialized }[0]
    assert_equal(pump_power, pump.to_PumpConstantSpeed.get.ratedPowerConsumption.get)
    assert_equal(collector_attached_to_tank, true)
  end

  def test_solar_fraction
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-solar-fraction.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.9, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(1.335, 'Btu/(hr*F)', 'W/K') * 0.35
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    ther_eff = 1.0
    loc = water_heating_system.location

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size)
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)
  end

  def test_tank_indirect
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-indirect.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.95, 'gal', 'm^3') # convert to actual volume
    cap = 0.0
    ua = UnitConversions.convert(5.056, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    loc = water_heating_system.location

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size)
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)

    # Heat exchanger
    assert_equal(1, model.getHeatExchangerFluidToFluids.size)
    hx = model.getHeatExchangerFluidToFluids[0]
    hx_attached_to_boiler = false
    hx_attached_to_tank = false
    model.getPlantLoops.each do |plant_loop|
      next if plant_loop.demandComponents.select { |comp| comp == hx }.empty?
      next if plant_loop.supplyComponents.select { |comp| comp.name.get.include? 'boiler' }.empty?

      hx_attached_to_boiler = true
    end
    model.getPlantLoops.each do |plant_loop|
      next if plant_loop.supplyComponents.select { |comp| comp == hx }.empty?
      next if plant_loop.demandComponents.select { |comp| comp == wh }.empty?

      hx_attached_to_tank = true
    end
    assert_equal(hx_attached_to_boiler, true)
    assert_equal(hx_attached_to_tank, true)
  end

  def test_tank_combi_tankless
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-combi-tankless.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(1, 'gal', 'm^3') # convert to actual volume
    cap = 0.0
    ua = 0.0
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') # setpoint + 1/2 deadband
    loc = water_heating_system.location

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size)
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_equal('Modulate', wh.heaterControlType)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)

    # Heat exchanger
    assert_equal(1, model.getHeatExchangerFluidToFluids.size)
    hx = model.getHeatExchangerFluidToFluids[0]
    hx_attached_to_boiler = false
    hx_attached_to_tank = false
    model.getPlantLoops.each do |plant_loop|
      next if plant_loop.demandComponents.select { |comp| comp == hx }.empty?
      next if plant_loop.supplyComponents.select { |comp| comp.name.get.include? 'boiler' }.empty?

      hx_attached_to_boiler = true
    end
    model.getPlantLoops.each do |plant_loop|
      next if plant_loop.supplyComponents.select { |comp| comp == hx }.empty?
      next if plant_loop.demandComponents.select { |comp| comp == wh }.empty?

      hx_attached_to_tank = true
    end
    assert_equal(hx_attached_to_boiler, true)
    assert_equal(hx_attached_to_tank, true)
  end

  def test_tank_heat_pump
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-tank-heat-pump.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.9, 'gal', 'm^3') # convert to actual volume
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    u =  0.925
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') - 9
    ther_eff = 1.0
    cop = 2.820
    tank_height = 1.598

    # Check water heater
    assert_equal(1, model.getWaterHeaterHeatPumpWrappedCondensers.size)
    assert_equal(1, model.getWaterHeaterStratifieds.size)
    hpwh = model.getWaterHeaterHeatPumpWrappedCondensers[0]
    wh = hpwh.tank.to_WaterHeaterStratified.get
    coil = hpwh.dXCoil.to_CoilWaterHeatingAirToWaterHeatPumpWrapped.get
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal('Schedule', wh.ambientTemperatureIndicator)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(tank_height, wh.tankHeight.get, 0.001)
    assert_in_epsilon(4500.0, wh.heater1Capacity.get, 0.001)
    assert_in_epsilon(4500.0, wh.heater2Capacity, 0.001)
    assert_in_epsilon(u, wh.uniformSkinLossCoefficientperUnitAreatoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.heater1SetpointTemperatureSchedule.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency, 0.001)

    # Check heat pump cooling coil cop
    assert_in_epsilon(cop, coil.ratedCOP, 0.001)
  end

  def test_tank_jacket
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-jacket-electric.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.9, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(0.6415, 'Btu/(hr*F)', 'W/K')
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    ther_eff = 1.0
    loc = water_heating_system.location

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size)
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)
  end

  def test_shared_water_heater
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-shared-water-heater.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]

    # Expected value
    tank_volume = UnitConversions.convert(water_heating_system.tank_volume * 0.95, 'gal', 'm^3') # convert to actual volume
    cap = UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')
    fuel = EPlus.fuel_type(water_heating_system.fuel_type)
    ua = UnitConversions.convert(7.88, 'Btu/(hr*F)', 'W/K') / water_heating_system.number_of_units_served
    t_set = UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1 # setpoint + 1/2 deadband
    ther_eff = 0.773
    loc = water_heating_system.location

    # Check water heater
    assert_equal(1, model.getWaterHeaterMixeds.size)
    wh = model.getWaterHeaterMixeds[0]
    assert_equal(fuel, wh.heaterFuelType)
    assert_equal(loc, wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volume, wh.tankVolume.get, 0.001)
    assert_in_epsilon(cap, wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(ua, wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(ua, wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_set, wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_eff, wh.heaterThermalEfficiency.get, 0.001)
  end

  def test_shared_laundry_room
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-dhw-shared-laundry-room.xml'))
    model, hpxml = _test_measure(args_hash)

    # Get HPXML values
    water_heating_system = hpxml.water_heating_systems[0]
    shared_water_heating_system = hpxml.water_heating_systems[1]

    # Expected value
    tank_volumes = [UnitConversions.convert(water_heating_system.tank_volume * 0.9, 'gal', 'm^3'),
                    UnitConversions.convert(shared_water_heating_system.tank_volume * 0.9, 'gal', 'm^3')] # convert to actual volume
    caps = [UnitConversions.convert(water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W'),
            UnitConversions.convert(shared_water_heating_system.heating_capacity / 1000.0, 'kBtu/hr', 'W')]
    fuels = [EPlus.fuel_type(water_heating_system.fuel_type),
             EPlus.fuel_type(shared_water_heating_system.fuel_type)]
    uas = [UnitConversions.convert(1.335, 'Btu/(hr*F)', 'W/K'),
           UnitConversions.convert(1.335 / shared_water_heating_system.number_of_units_served, 'Btu/(hr*F)', 'W/K')]
    t_sets = [UnitConversions.convert(water_heating_system.temperature, 'F', 'C') + 1,
              UnitConversions.convert(shared_water_heating_system.temperature, 'F', 'C') + 1] # setpoint + 1/2 deadband
    ther_effs = [1.0, 1.0]
    locs = [water_heating_system.location,
            shared_water_heating_system.location]

    # Check water heater
    assert_equal(2, model.getWaterHeaterMixeds.size)
    wh = model.getWaterHeaterMixeds.sort[0]
    assert_equal(fuels[0], wh.heaterFuelType)
    assert_equal(locs[0], wh.ambientTemperatureThermalZone.get.name.get)
    assert_in_epsilon(tank_volumes[0], wh.tankVolume.get, 0.001)
    assert_in_epsilon(caps[0], wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(uas[0], wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(uas[0], wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_sets[0], wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_effs[0], wh.heaterThermalEfficiency.get, 0.001)
    wh = model.getWaterHeaterMixeds.sort[1]
    assert_equal(fuels[1], wh.heaterFuelType)
    assert_equal('Schedule', wh.ambientTemperatureIndicator)
    assert_in_epsilon(tank_volumes[1], wh.tankVolume.get, 0.001)
    assert_in_epsilon(caps[1], wh.heaterMaximumCapacity.get, 0.001)
    assert_in_epsilon(uas[1], wh.onCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(uas[1], wh.offCycleLossCoefficienttoAmbientTemperature.get, 0.001)
    assert_in_epsilon(t_sets[1], wh.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value, 0.001)
    assert_in_epsilon(ther_effs[1], wh.heaterThermalEfficiency.get, 0.001)
  end

  def _test_measure(args_hash)
    # create an instance of the measure
    measure = HPXMLtoOpenStudio.new

    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    model = OpenStudio::Model::Model.new

    # get arguments
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

    return model, hpxml
  end
end
