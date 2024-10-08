# frozen_string_literal: true

# Collection of methods related to airflow modeling (e.g., infiltration, natural ventilation,
# mechanical ventilation, ducts, etc.).
module Airflow
  # Constants
  InfilPressureExponent = 0.65
  AssumedInsideTemp = 73.5 # (F)
  Gravity = 32.174 # acceleration of gravity (ft/s2)

  # Adds HPXML Air Infiltration and HPXML HVAC Distribution to the OpenStudio model.
  # TODO for adding more description (e.g., around checks and warnings)
  #
  # @param runner [OpenStudio::Measure::OSRunner] Object typically used to display warnings
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param hpxml_header [HPXML::Header] HPXML Header object (one per HPXML file)
  # @param schedules_file [SchedulesFile] SchedulesFile wrapper class instance of detailed schedule files
  # @param airloop_map [Hash] Map of HPXML System ID => OpenStudio AirLoopHVAC (or ZoneHVACFourPipeFanCoil or ZoneHVACBaseboardConvectiveWater) objects
  # @return [nil]
  def self.apply(runner, model, weather, spaces, hpxml_bldg, hpxml_header, schedules_file, airloop_map)
    sensors = create_sensors(runner, model, spaces, hpxml_header)

    # Ventilation fans
    vent_fans = { mech: [], cfis_suppl: [], whf: [], kitchen: [], bath: [] }
    hpxml_bldg.ventilation_fans.each do |f|
      next unless f.hours_in_operation.nil? || f.hours_in_operation > 0

      if f.used_for_whole_building_ventilation
        if not f.is_cfis_supplemental_fan
          vent_fans[:mech] << f
        else
          vent_fans[:cfis_suppl] << f
        end
      elsif f.used_for_seasonal_cooling_load_reduction
        vent_fans[:whf] << f
      elsif f.used_for_local_ventilation
        if f.fan_location == HPXML::LocationKitchen
          vent_fans[:kitchen] << f
        elsif f.fan_location == HPXML::LocationBath
          vent_fans[:bath] << f
        end
      end
    end

    # Initialization
    cfis_data = initialize_cfis(model, vent_fans, airloop_map, hpxml_header.unavailable_periods)
    fan_data = { rtf_var: {}, mfr_max_var: {}, rtf_sensor: {} }
    model.getAirLoopHVACs.each do |air_loop|
      initialize_fan_objects(model, air_loop, fan_data)
    end
    model.getZoneHVACFourPipeFanCoils.each do |fan_coil|
      initialize_fan_objects(model, fan_coil, fan_data)
    end

    # Apply ducts

    duct_lk_imbals = []
    adiabatic_const = nil
    duct_systems = create_duct_systems(model, spaces, hpxml_bldg, airloop_map)
    check_duct_leakage(runner, hpxml_bldg)
    duct_systems.each do |ducts, object|
      adiabatic_const = apply_ducts(model, spaces, hpxml_bldg, ducts, object, vent_fans, cfis_data, fan_data, duct_lk_imbals, sensors, adiabatic_const)
    end

    # Apply infiltration/ventilation
    set_wind_speed_correction(model, hpxml_bldg)

    infil_values = get_values_from_air_infiltration_measurements(hpxml_bldg, weather)

    # Cooling season schedule
    # Applies to natural ventilation, not HVAC equipment.
    # Uses BAHSP cooling season, not user-specified cooling season (which may be, e.g., year-round).
    _, default_cooling_months = HVAC.get_default_heating_and_cooling_seasons(weather, hpxml_bldg.latitude)
    clg_season_sch = MonthWeekdayWeekendSchedule.new(model, 'cooling season schedule', Array.new(24, 1), Array.new(24, 1), default_cooling_months, EPlus::ScheduleTypeLimitsFraction)
    clg_ssn_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Schedule Value')
    clg_ssn_sensor.setName('cool_season')
    clg_ssn_sensor.setKeyName(clg_season_sch.schedule.name.to_s)

    # Natural ventilation and whole house fans
    apply_natural_ventilation_and_whole_house_fan(runner, model, spaces, hpxml_bldg, hpxml_header, vent_fans, clg_ssn_sensor, infil_values, sensors)

    # Infiltration/ventilation for unconditioned spaces
    apply_infiltration_to_garage(model, spaces, hpxml_bldg, infil_values, duct_lk_imbals)
    apply_infiltration_to_unconditioned_basement(model, spaces, duct_lk_imbals)
    apply_infiltration_to_vented_crawlspace(model, spaces, weather, hpxml_bldg, duct_lk_imbals)
    apply_infiltration_to_unvented_crawlspace(model, spaces, duct_lk_imbals)
    apply_infiltration_to_vented_attic(model, spaces, weather, hpxml_bldg, hpxml_header, duct_lk_imbals)
    apply_infiltration_to_unvented_attic(model, spaces, duct_lk_imbals)

    # Infiltration/ventilation for conditioned space
    apply_infiltration_ventilation_to_conditioned(runner, model, spaces, weather, hpxml_bldg, hpxml_header, vent_fans, infil_values,
                                                  clg_ssn_sensor, schedules_file, duct_lk_imbals, cfis_data, fan_data, sensors)
  end

  # Creates a variety of EMS sensors used in airflow calculations.
  #
  # @param runner [OpenStudio::Measure::OSRunner] Object typically used to display warnings
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param hpxml_header [HPXML::Header] HPXML Header object (one per HPXML file)
  # @return [Hash] Map of :sensor_types => EMS sensors
  def self.create_sensors(runner, model, spaces, hpxml_header)
    conditioned_space = spaces[HPXML::LocationConditionedSpace]
    conditioned_zone = conditioned_space.thermalZone.get

    sensors = {}

    sensors[:pbar] = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Site Outdoor Air Barometric Pressure')
    sensors[:pbar].setName('out pb s')

    sensors[:w_out] = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Site Outdoor Air Humidity Ratio')
    sensors[:w_out].setName('out wt s')

    sensors[:w_in] = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Zone Air Humidity Ratio')
    sensors[:w_in].setName('win s')
    sensors[:w_in].setKeyName(conditioned_zone.name.to_s)

    sensors[:v_wind] = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Site Wind Speed')
    sensors[:v_wind].setName('site vw s')

    sensors[:t_in] = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Zone Mean Air Temperature')
    sensors[:t_in].setName('tin s')
    sensors[:t_in].setKeyName(conditioned_zone.name.to_s)

    sensors[:t_out] = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Zone Outdoor Air Drybulb Temperature')
    sensors[:t_out].setName('tout s')
    sensors[:t_out].setKeyName(conditioned_zone.name.to_s)

    # Create HVAC availability sensor
    sensors[:hvac_avail] = nil
    heating_unavailable_periods = Schedule.get_unavailable_periods(runner, SchedulesFile::Columns[:SpaceHeating].name, hpxml_header.unavailable_periods)
    cooling_unavailable_periods = Schedule.get_unavailable_periods(runner, SchedulesFile::Columns[:SpaceCooling].name, hpxml_header.unavailable_periods)
    if (not heating_unavailable_periods.empty?) || (not cooling_unavailable_periods.empty?)
      avail_sch = ScheduleConstant.new(model, 'hvac availability schedule', 1.0, EPlus::ScheduleTypeLimitsFraction, unavailable_periods: heating_unavailable_periods + cooling_unavailable_periods)

      sensors[:hvac_avail] = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Schedule Value')
      sensors[:hvac_avail].setName("#{avail_sch.schedule.name} s")
      sensors[:hvac_avail].setKeyName(avail_sch.schedule.name.to_s)
      sensors[:hvac_avail].additionalProperties.setFeature('ObjectType', Constants::ObjectTypeHVACAvailabilitySensor)
    end

    return sensors
  end

  # TODO
  #
  # @return [TODO] TODO
  def self.get_default_fraction_of_windows_operable()
    # Combining the value below with the assumption that 50% of
    # the area of an operable window can be open produces the
    # Building America assumption that "Thirty-three percent of
    # the window area ... can be opened for natural ventilation"
    return 0.67 # 67%
  end

  # TODO
  #
  # @return [TODO] TODO
  def self.get_default_vented_attic_sla()
    return (1.0 / 300.0).round(6) # Table 4.2.2(1) - Attics
  end

  # TODO
  #
  # @return [TODO] TODO
  def self.get_default_vented_crawl_sla()
    return (1.0 / 150.0).round(6) # Table 4.2.2(1) - Crawlspaces
  end

  # TODO
  #
  # @return [TODO] TODO
  def self.get_default_unvented_space_ach()
    return 0.1 # Assumption
  end

  # TODO
  #
  # @param vent_fan [TODO] TODO
  # @param eri_version [String] Version of the ANSI/RESNET/ICC 301 Standard to use for equations/assumptions
  # @return [TODO] TODO
  def self.get_default_mech_vent_fan_power(vent_fan, eri_version)
    # Returns fan power in W/cfm, based on ANSI 301
    if vent_fan.is_shared_system
      return 1.00 # Table 4.2.2(1) Note (n)
    elsif [HPXML::MechVentTypeSupply, HPXML::MechVentTypeExhaust].include? vent_fan.fan_type
      return 0.35
    elsif [HPXML::MechVentTypeBalanced].include? vent_fan.fan_type
      return 0.70
    elsif [HPXML::MechVentTypeERV, HPXML::MechVentTypeHRV].include? vent_fan.fan_type
      return 1.00
    elsif [HPXML::MechVentTypeCFIS].include? vent_fan.fan_type
      if Constants::ERIVersions.index(eri_version) >= Constants::ERIVersions.index('2022')
        return 0.58
      else
        return 0.50
      end
    else
      fail "Unexpected fan_type: '#{fan_type}'."
    end
  end

  # Returns the single infiltration measurement object of interest, from all possible infiltration measurements
  # in the HPXML file, that has the sufficient inputs. For EnergyPlus, we return a measurement with a quantitative
  # value (e.g., ACH50) if available, otherwise fallback to the qualitative input. For Manual J design loads, the
  # returned measurement is controlled by the manualj_infiltration_method argument.
  #
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param manualj_infiltration_method [String] Type of infiltration to retrieve for Manual J calculations
  # @return measurement [HPXML::AirInfiltrationMeasurement] Air infiltration measurement of interest
  def self.get_infiltration_measurement_of_interest(hpxml_bldg, manualj_infiltration_method: nil)
    if manualj_infiltration_method.nil? || (manualj_infiltration_method == HPXML::ManualJInfiltrationMethodBlowerDoor)
      hpxml_bldg.air_infiltration_measurements.each do |measurement|
        # Returns the infiltration measurement that has the minimum information needed for simulation
        if measurement.air_leakage
          if [HPXML::UnitsACH, HPXML::UnitsCFM].include?(measurement.unit_of_measure) && !measurement.house_pressure.nil?
            return measurement
          elsif [HPXML::UnitsACHNatural, HPXML::UnitsCFMNatural].include? measurement.unit_of_measure
            return measurement
          end
        elsif measurement.effective_leakage_area
          return measurement
        end
      end
    end

    if manualj_infiltration_method.nil? || (manualj_infiltration_method == HPXML::ManualJInfiltrationMethodDefaultTable)
      hpxml_bldg.air_infiltration_measurements.each do |measurement|
        return measurement if measurement.leakiness_description
      end
    end

    fail 'Could not find air infiltration measurement.'
  end

  # TODO
  #
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param weather [WeatherFile] Weather object containing EPW information
  # @return [TODO] TODO
  def self.get_values_from_air_infiltration_measurements(hpxml_bldg, weather)
    cfa = hpxml_bldg.building_construction.conditioned_floor_area
    measurement = get_infiltration_measurement_of_interest(hpxml_bldg)

    infil_volume = measurement.infiltration_volume
    infil_height = measurement.infiltration_height
    if infil_height.nil?
      infil_height = hpxml_bldg.inferred_infiltration_height(infil_volume)
    end

    sla, ach50, nach = nil
    if [HPXML::UnitsACH, HPXML::UnitsCFM].include?(measurement.unit_of_measure)
      if measurement.unit_of_measure == HPXML::UnitsACH
        ach50 = calc_air_leakage_at_diff_pressure(InfilPressureExponent, measurement.air_leakage, measurement.house_pressure, 50.0)
      elsif measurement.unit_of_measure == HPXML::UnitsCFM
        achXX = measurement.air_leakage * 60.0 / infil_volume # Convert CFM to ACH
        ach50 = calc_air_leakage_at_diff_pressure(InfilPressureExponent, achXX, measurement.house_pressure, 50.0)
      end
      sla = get_infiltration_SLA_from_ACH50(ach50, InfilPressureExponent, cfa, infil_volume)
      nach = get_infiltration_ACH_from_SLA(sla, infil_height, weather)
    elsif [HPXML::UnitsACHNatural, HPXML::UnitsCFMNatural].include? measurement.unit_of_measure
      if measurement.unit_of_measure == HPXML::UnitsACHNatural
        nach = measurement.air_leakage
      elsif measurement.unit_of_measure == HPXML::UnitsCFMNatural
        nach = measurement.air_leakage * 60.0 / infil_volume # Convert CFM to ACH
      end
      avg_ceiling_height = hpxml_bldg.building_construction.average_ceiling_height
      sla = get_infiltration_SLA_from_ACH(nach, infil_height, avg_ceiling_height, weather)
      ach50 = get_infiltration_ACH50_from_SLA(sla, InfilPressureExponent, cfa, infil_volume)
    elsif !measurement.effective_leakage_area.nil?
      sla = UnitConversions.convert(measurement.effective_leakage_area, 'in^2', 'ft^2') / cfa
      ach50 = get_infiltration_ACH50_from_SLA(sla, InfilPressureExponent, cfa, infil_volume)
      nach = get_infiltration_ACH_from_SLA(sla, infil_height, weather)
    else
      fail 'Unexpected error.'
    end

    if measurement.infiltration_type == HPXML::InfiltrationTypeUnitTotal
      a_ext = measurement.a_ext # Adjustment ratio for SFA/MF units; exterior envelope area divided by total envelope area
    end
    a_ext = 1.0 if a_ext.nil?

    return { sla: sla, ach50: ach50, nach: nach, volume: infil_volume, height: infil_height, a_ext: a_ext }
  end

  # Calculate ACH50 for annual energy simulation when only leakiness description is provided.
  #
  # Uses a regression developed by LBNL using ResDB data (https://resdb.lbl.gov) that takes into account IECC zone,
  # cfa, year built, foundation type, duct location, etc. The leakiness description is then used to further adjust
  # the default (average) infiltration rate.
  #
  # @param cfa [Double] Conditioned floor area in the dwelling unit (ft2)
  # @param ncfl_ag [Double] Number of conditioned floors above grade
  # @param year_built [Integer] Year the dwelling unit is built
  # @param avg_ceiling_height [Double] Average floor to ceiling height within conditioned space (ft2)
  # @param infil_volume [Double] Volume of space most impacted by the blower door test (ft3)
  # @param iecc_cz [String] IECC climate zone
  # @param fnd_type_fracs [Hash] Map of foundation type => area fraction
  # @param duct_loc_fracs [Hash] Map of duct location => area fraction
  # @param leakiness_description [String] Leakiness description to qualitatively describe the dwelling unit infiltration
  # @param air_sealed [Boolean] True if the dwelling unit was professionally air sealed (intended to be used by Home Energy Score)
  # @return [Double] Calculated ACH50 value
  def self.calc_ach50_from_leakiness_description(cfa, ncfl_ag, year_built, avg_ceiling_height, infil_volume, iecc_cz,
                                                 fnd_type_fracs, duct_loc_fracs, leakiness_description = nil, is_sealed = false)
    # Constants
    c_floor_area = -0.002078
    c_height = 0.06375
    # Multiplier summarized from Manual J 5A & 5B tables, average of all (values at certain leakiness description / average leakiness)
    leakage_multiplier_map = { HPXML::LeakinessVeryTight => 0.355,
                               HPXML::LeakinessTight => 0.686,
                               HPXML::LeakinessAverage => 1.0,
                               HPXML::LeakinessLeaky => 1.549,
                               HPXML::LeakinessVeryLeaky => 2.085 }
    leakage_multiplier = leakiness_description.nil? ? 1.0 : leakage_multiplier_map[leakiness_description]
    c_sealed = is_sealed ? -0.288 : 0.0

    # Vintage
    c_vintage = nil
    if year_built < 1960
      c_vintage = -0.2498
    elsif year_built <= 1969
      c_vintage = -0.4327
    elsif year_built <= 1979
      c_vintage = -0.4521
    elsif year_built <= 1989
      c_vintage = -0.6536
    elsif year_built <= 1999
      c_vintage = -0.9152
    elsif year_built >= 2000
      c_vintage = -1.058
    else
      fail "Unexpected vintage: #{year_built}"
    end

    # Climate zone
    c_iecc = nil
    if (iecc_cz == '1A') || (iecc_cz == '2A')
      c_iecc = 0.4727
    elsif iecc_cz == '3A'
      c_iecc = 0.2529
    elsif iecc_cz == '4A'
      c_iecc = 0.3261
    elsif iecc_cz == '5A'
      c_iecc = 0.1118
    elsif (iecc_cz == '6A') || (iecc_cz == '7')
      c_iecc = 0.0
    elsif (iecc_cz == '2B') || (iecc_cz == '3B')
      c_iecc = -0.03755
    elsif (iecc_cz == '4B') || (iecc_cz == '5B')
      c_iecc = -0.008774
    elsif iecc_cz == '6B'
      c_iecc = 0.01944
    elsif iecc_cz == '3C'
      c_iecc = 0.04827
    elsif iecc_cz == '4C'
      c_iecc = 0.2584
    elsif iecc_cz == '8'
      c_iecc = -0.5119
    else
      fail "Unexpected IECC climate zone: #{c_iecc}"
    end

    # Foundation type (weight by area)
    c_foundation = 0.0
    fnd_type_fracs.each do |foundation_type, area_fraction|
      case foundation_type
      when HPXML::FoundationTypeSlab, HPXML::FoundationTypeAboveApartment
        c_foundation -= 0.036992 * area_fraction
      when HPXML::FoundationTypeBasementConditioned, HPXML::FoundationTypeCrawlspaceUnvented, HPXML::FoundationTypeCrawlspaceConditioned
        c_foundation += 0.108713 * area_fraction
      when HPXML::FoundationTypeBasementUnconditioned, HPXML::FoundationTypeCrawlspaceVented, HPXML::FoundationTypeBellyAndWing, HPXML::FoundationTypeAmbient
        c_foundation += 0.180352 * area_fraction
      else
        fail "Unexpected foundation type: #{foundation_type}"
      end
    end

    c_duct = 0.0
    duct_loc_fracs.each do |duct_location, area_fraction|
      if (HPXML::conditioned_locations + HPXML::multifamily_common_space_locations + [HPXML::LocationUnderSlab, HPXML::LocationExteriorWall, HPXML::LocationOutside, HPXML::LocationRoofDeck, HPXML::LocationManufacturedHomeBelly]).include? duct_location
        c_duct -= 0.12381 * area_fraction
      elsif [HPXML::LocationAtticUnvented, HPXML::LocationBasementUnconditioned, HPXML::LocationGarage, HPXML::LocationCrawlspaceUnvented].include? duct_location
        c_duct += 0.07126 * area_fraction
      elsif HPXML::vented_locations.include? duct_location
        c_duct += 0.18072 * area_fraction
      else
        fail "Unexpected duct location: #{duct_location}"
      end
    end

    floor_area_m2 = UnitConversions.convert(cfa, 'ft^2', 'm^2')
    height_m = UnitConversions.convert(ncfl_ag * avg_ceiling_height, 'ft', 'm') + 0.5

    # Normalized leakage
    nl = Math.exp(floor_area_m2 * c_floor_area + height_m * c_height +
                  c_sealed + c_vintage + c_iecc + c_foundation + c_duct) * leakage_multiplier

    # Specific Leakage Area
    sla = nl / (1000.0 * ncfl_ag**0.3)

    ach50 = get_infiltration_ACH50_from_SLA(sla, 0.65, cfa, infil_volume)

    return ach50
  end

  # TODO
  #
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param vent_fan [TODO] TODO
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param eri_version [String] Version of the ANSI/RESNET/ICC 301 Standard to use for equations/assumptions
  # @return [TODO] TODO
  def self.get_default_mech_vent_flow_rate(hpxml_bldg, vent_fan, weather, eri_version)
    # Calculates Qfan cfm requirement per ASHRAE 62.2 / ANSI 301
    cfa = hpxml_bldg.building_construction.conditioned_floor_area
    nbeds = hpxml_bldg.building_construction.number_of_bedrooms
    infil_values = get_values_from_air_infiltration_measurements(hpxml_bldg, weather)
    bldg_type = hpxml_bldg.building_construction.residential_facility_type

    nl = get_infiltration_NL_from_SLA(infil_values[:sla], infil_values[:height])
    q_inf = get_infiltration_Qinf_from_NL(nl, weather, cfa)
    q_tot = get_mech_vent_qtot_cfm(nbeds, cfa)
    if vent_fan.is_balanced
      is_balanced, frac_imbal = true, 0.0
    else
      is_balanced, frac_imbal = false, 1.0
    end
    q_fan = get_mech_vent_qfan_cfm(q_tot, q_inf, is_balanced, frac_imbal, infil_values[:a_ext], bldg_type, eri_version, vent_fan.hours_in_operation)
    return q_fan
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [nil]
  def self.set_wind_speed_correction(model, hpxml_bldg)
    site = hpxml_bldg.site
    site_ap = site.additional_properties

    site_map = { HPXML::SiteTypeRural => 'Country',    # Flat, open country
                 HPXML::SiteTypeSuburban => 'Suburbs', # Rough, wooded country, suburbs
                 HPXML::SiteTypeUrban => 'City' }      # Towns, city outskirts, center of large cities
    model.getSite.setTerrain(site_map[site.site_type])

    site_ap.height = 32.8 # ft (Standard weather station height)

    # Open, Unrestricted at Weather Station
    site_ap.terrain_multiplier = 1.0
    site_ap.terrain_exponent = 0.15
    site_ap.ashrae_terrain_thickness = 270
    site_ap.ashrae_terrain_exponent = 0.14

    if site.site_type == HPXML::SiteTypeRural
      site_ap.site_terrain_multiplier = 0.85
      site_ap.site_terrain_exponent = 0.20
      site_ap.ashrae_site_terrain_thickness = 270 # Flat, open country
      site_ap.ashrae_site_terrain_exponent = 0.14 # Flat, open country
    elsif site.site_type == HPXML::SiteTypeSuburban
      site_ap.site_terrain_multiplier = 0.67
      site_ap.site_terrain_exponent = 0.25
      site_ap.ashrae_site_terrain_thickness = 370 # Rough, wooded country, suburbs
      site_ap.ashrae_site_terrain_exponent = 0.22 # Rough, wooded country, suburbs
    elsif site.site_type == HPXML::SiteTypeUrban
      site_ap.site_terrain_multiplier = 0.47
      site_ap.site_terrain_exponent = 0.35
      site_ap.ashrae_site_terrain_thickness = 460 # Towns, city outskirts, center of large cities
      site_ap.ashrae_site_terrain_exponent = 0.33 # Towns, city outskirts, center of large cities
    end

    # Mapping based on AIM-2 Model by Walker/Wilson
    # Table 2: Estimates of Shelter Coefficient S_wo for No Flue (flue effect is handled later)
    if site.shielding_of_home == HPXML::ShieldingNormal
      site_ap.aim2_shelter_coeff = 0.50 # Class 4: "Very heavy shielding, many large obstructions within one house height"
    elsif site.shielding_of_home == HPXML::ShieldingExposed
      site_ap.aim2_shelter_coeff = 0.90 # Class 2: "Light local shielding with few obstructions within two house heights"
    elsif site.shielding_of_home == HPXML::ShieldingWellShielded
      site_ap.aim2_shelter_coeff = 0.30 # Class 5: "Complete shielding, with large buildings immediately adjacent"
    end

    # S-G Shielding Coefficients are roughly 1/3 of AIM2 Shelter Coefficients
    site_ap.s_g_shielding_coef = site_ap.aim2_shelter_coeff / 3.0
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param space [OpenStudio::Model::Space] an OpenStudio::Model::Space object
  # @param ach [TODO] TODO
  # @param ela [TODO] TODO
  # @param c_w_SG [TODO] TODO
  # @param c_s_SG [TODO] TODO
  # @param duct_lk_imbals [TODO] TODO
  # @return [nil]
  def self.apply_infiltration_to_unconditioned_space(model, space, ach, ela, c_w_SG, c_s_SG, duct_lk_imbals)
    # Infiltration/Ventilation

    if ach.to_f > 0
      # Model ACH as a constant flow rate (typically used for below-grade spaces where wind is zero)
      flow_rate = OpenStudio::Model::SpaceInfiltrationDesignFlowRate.new(model)
      flow_rate.setName("#{Constants::ObjectTypeInfiltration}|#{space.name}")
      flow_rate.setSchedule(model.alwaysOnDiscreteSchedule)
      flow_rate.setAirChangesperHour(ach)
      flow_rate.setSpace(space)
      flow_rate.setConstantTermCoefficient(1)
      flow_rate.setTemperatureTermCoefficient(0)
      flow_rate.setVelocityTermCoefficient(0)
      flow_rate.setVelocitySquaredTermCoefficient(0)
    elsif ela.to_f > 0
      # Model ELA with stack/wind coefficients
      leakage_area = OpenStudio::Model::SpaceInfiltrationEffectiveLeakageArea.new(model)
      leakage_area.setName("#{Constants::ObjectTypeInfiltration}|#{space.name}")
      leakage_area.setSchedule(model.alwaysOnDiscreteSchedule)
      leakage_area.setEffectiveAirLeakageArea(UnitConversions.convert(ela, 'ft^2', 'cm^2'))
      leakage_area.setStackCoefficient(UnitConversions.convert(c_s_SG, 'ft^2/(s^2*R)', 'L^2/(s^2*cm^4*K)'))
      leakage_area.setWindCoefficient(c_w_SG * 0.01)
      leakage_area.setSpace(space)
    end

    # Duct leakage imbalance induced infiltration

    # Technically the duct leakage imbalance interacts with the infiltration/ventilation,
    # but the interaction is not that important to capture for an unconditioned space.
    if duct_lk_imbals.any? { |values| values[0] == space.thermalZone.get.name.to_s }
      space_name = space.name.to_s.gsub(' - ', '_')

      uncond_infil_flow = OpenStudio::Model::SpaceInfiltrationDesignFlowRate.new(model)
      uncond_infil_flow.setName("#{space_name} duct leakage imbalance infil flow")
      uncond_infil_flow.setSchedule(model.alwaysOnDiscreteSchedule)
      uncond_infil_flow.setSpace(space)
      uncond_infil_flow_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(uncond_infil_flow, *EPlus::EMSActuatorZoneInfiltrationFlowRate)
      uncond_infil_flow_actuator.setName("#{uncond_infil_flow.name} act")

      # Unconditioned Space Duct Leakage Imbalance Induced Infiltration Program
      uncond_infil_program = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
      uncond_infil_program.setName("#{space_name} duct leakage imbalance infil program")
      uncond_infil_program.addLine('Set Qducts = 0')
      duct_lk_imbals.each do |values|
        duct_location, duct_lk_supply_fan_equiv_var, duct_lk_exhaust_fan_equiv_var = values
        next if duct_location != space.thermalZone.get.name.to_s

        uncond_infil_program.addLine("Set Qducts = Qducts - #{duct_lk_supply_fan_equiv_var.name}")
        uncond_infil_program.addLine("Set Qducts = Qducts + #{duct_lk_exhaust_fan_equiv_var.name}")
      end
      uncond_infil_program.addLine("Set #{uncond_infil_flow_actuator.name} = (@Abs(Qducts))")

      program_calling_manager = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
      program_calling_manager.setName("#{uncond_infil_program.name} calling manager")
      program_calling_manager.setCallingPoint('BeginZoneTimestepAfterInitHeatBalance')
      program_calling_manager.addProgram(uncond_infil_program)
    end
  end

  # TODO
  #
  # @param runner [OpenStudio::Measure::OSRunner] Object typically used to display warnings
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param hpxml_header [HPXML::Header] HPXML Header object (one per HPXML file)
  # @param vent_fans [TODO] TODO
  # @param nv_clg_ssn_sensor [TODO] TODO
  # @param infil_values [Hash] TODO
  # @param sensors [Hash] Map of :sensor_types => EMS sensors
  # @return [nil]
  def self.apply_natural_ventilation_and_whole_house_fan(runner, model, spaces, hpxml_bldg, hpxml_header, vent_fans, nv_clg_ssn_sensor,
                                                         infil_values, sensors)

    conditioned_space = spaces[HPXML::LocationConditionedSpace]
    conditioned_zone = conditioned_space.thermalZone.get

    # NV Availability Schedule
    nv_avail_sch = create_nv_and_whf_avail_sch(model, Constants::ObjectTypeNaturalVentilation, hpxml_bldg.header.natvent_days_per_week, hpxml_header.unavailable_periods)

    nv_avail_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Schedule Value')
    nv_avail_sensor.setName("#{Constants::ObjectTypeNaturalVentilation} s")
    nv_avail_sensor.setKeyName(nv_avail_sch.name.to_s)

    # Availability Schedules paired with vent fan class
    # If whf_num_days_per_week is exposed, can handle multiple fans with different days of operation
    whf_avail_sensors = {}
    vent_fans[:whf].each_with_index do |vent_whf, index|
      whf_num_days_per_week = 7 # FUTURE: Expose via HPXML?
      obj_name = "#{Constants::ObjectTypeWholeHouseFan} #{index}"
      whf_unavailable_periods = Schedule.get_unavailable_periods(runner, SchedulesFile::Columns[:WholeHouseFan].name, hpxml_header.unavailable_periods)
      whf_avail_sch = create_nv_and_whf_avail_sch(model, obj_name, whf_num_days_per_week, whf_unavailable_periods)

      whf_avail_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Schedule Value')
      whf_avail_sensor.setName("#{obj_name} s")
      whf_avail_sensor.setKeyName(whf_avail_sch.name.to_s)
      whf_avail_sensors[vent_whf.id] = whf_avail_sensor
    end

    # Sensors
    if conditioned_zone.thermostatSetpointDualSetpoint.is_initialized
      thermostat = conditioned_zone.thermostatSetpointDualSetpoint.get

      htg_sp_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Schedule Value')
      htg_sp_sensor.setName('htg sp s')
      htg_sp_sensor.setKeyName(thermostat.heatingSetpointTemperatureSchedule.get.name.to_s)

      clg_sp_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Schedule Value')
      clg_sp_sensor.setName('clg sp s')
      clg_sp_sensor.setKeyName(thermostat.coolingSetpointTemperatureSchedule.get.name.to_s)
    end

    # Actuators
    nv_flow = OpenStudio::Model::SpaceInfiltrationDesignFlowRate.new(model)
    nv_flow.setName(Constants::ObjectTypeNaturalVentilation + ' flow')
    nv_flow.setSchedule(model.alwaysOnDiscreteSchedule)
    nv_flow.setSpace(conditioned_space)
    nv_flow_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(nv_flow, *EPlus::EMSActuatorZoneInfiltrationFlowRate)
    nv_flow_actuator.setName("#{nv_flow.name} act")
    nv_flow.additionalProperties.setFeature('ObjectType', Constants::ObjectTypeNaturalVentilation)

    whf_flow = OpenStudio::Model::SpaceInfiltrationDesignFlowRate.new(model)
    whf_flow.setName(Constants::ObjectTypeWholeHouseFan + ' flow')
    whf_flow.setSchedule(model.alwaysOnDiscreteSchedule)
    whf_flow.setSpace(conditioned_space)
    whf_flow_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(whf_flow, *EPlus::EMSActuatorZoneInfiltrationFlowRate)
    whf_flow_actuator.setName("#{whf_flow.name} act")
    whf_flow.additionalProperties.setFeature('ObjectType', Constants::ObjectTypeWholeHouseFan)

    # Electric Equipment (for whole house fan electricity consumption)
    whf_equip_def = OpenStudio::Model::ElectricEquipmentDefinition.new(model)
    whf_equip_def.setName(Constants::ObjectTypeWholeHouseFan)
    whf_equip = OpenStudio::Model::ElectricEquipment.new(whf_equip_def)
    whf_equip.setName(Constants::ObjectTypeWholeHouseFan)
    whf_equip.setSpace(conditioned_space) # no heat gain, so assign the equipment to an arbitrary space
    whf_equip_def.setFractionRadiant(0)
    whf_equip_def.setFractionLatent(0)
    whf_equip_def.setFractionLost(1)
    whf_equip.setSchedule(model.alwaysOnDiscreteSchedule)
    whf_equip.setEndUseSubcategory(Constants::ObjectTypeWholeHouseFan)
    whf_elec_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(whf_equip, *EPlus::EMSActuatorElectricEquipmentPower, whf_equip.space.get)
    whf_elec_actuator.setName("#{whf_equip.name} act")

    # Assume located in attic floor if attic zone exists; otherwise assume it's through roof/wall.
    whf_zone = nil
    if not spaces[HPXML::LocationAtticVented].nil?
      whf_zone = spaces[HPXML::LocationAtticVented].thermalZone.get
    elsif not spaces[HPXML::LocationAtticUnvented].nil?
      whf_zone = spaces[HPXML::LocationAtticUnvented].thermalZone.get
    end
    if not whf_zone.nil?
      # Air from conditioned space to WHF zone (attic)
      zone_mixing = OpenStudio::Model::ZoneMixing.new(whf_zone)
      zone_mixing.setName("#{Constants::ObjectTypeWholeHouseFan} mix")
      zone_mixing.setSourceZone(conditioned_zone)
      cond_to_zone_flow_rate_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(zone_mixing, *EPlus::EMSActuatorZoneMixingFlowRate)
      cond_to_zone_flow_rate_actuator.setName("#{zone_mixing.name} act")
    end

    # Assume A) 50% of the area of an operable window can be open, and B) 20% of openable window area is actually open
    window_area = hpxml_bldg.windows.map { |w| w.area }.sum(0.0)
    open_window_area = window_area * hpxml_bldg.additional_properties.initial_frac_windows_operable * 0.5 * 0.2

    area = 0.6 * open_window_area # ft^2, for Sherman-Grimsrud
    max_rate = 20.0 # Air Changes per hour
    max_flow_rate = max_rate * infil_values[:volume] / UnitConversions.convert(1.0, 'hr', 'min')
    neutral_level = 0.5
    hor_lk_frac = 0.0
    c_w, c_s = calc_wind_stack_coeffs(hpxml_bldg, hor_lk_frac, neutral_level, conditioned_space, infil_values[:height])
    max_oa_hr = 0.0115 # From ANSI 301-2022

    # Program
    vent_program = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
    vent_program.additionalProperties.setFeature('ObjectType', Constants::ObjectTypeNaturalVentilation)
    vent_program.setName(Constants::ObjectTypeNaturalVentilation + ' program')
    vent_program.addLine("Set Tin = #{sensors[:t_in].name}")
    vent_program.addLine("Set Tout = #{sensors[:t_out].name}")
    vent_program.addLine("Set Wout = #{sensors[:w_out].name}")
    vent_program.addLine("Set Pbar = #{sensors[:pbar].name}")
    vent_program.addLine('Set Phiout = (@RhFnTdbWPb Tout Wout Pbar)')
    vent_program.addLine("Set MaxHR = #{max_oa_hr}")
    if not thermostat.nil?
      # Home has HVAC system (though setpoints may be defaulted); use the average of heating/cooling setpoints to minimize incurring additional heating energy.
      vent_program.addLine("Set Tnvsp = (#{htg_sp_sensor.name} + #{clg_sp_sensor.name}) / 2")
    else
      # No HVAC system; use the average of defaulted heating/cooling setpoints.
      htg_weekday_setpoints, htg_weekend_setpoints = HVAC.get_default_heating_setpoint(HPXML::HVACControlTypeManual, hpxml_header.eri_calculation_version)
      clg_weekday_setpoints, clg_weekend_setpoints = HVAC.get_default_cooling_setpoint(HPXML::HVACControlTypeManual, hpxml_header.eri_calculation_version)
      if htg_weekday_setpoints.split(', ').uniq.size == 1 && htg_weekend_setpoints.split(', ').uniq.size == 1 && htg_weekday_setpoints.split(', ').uniq == htg_weekend_setpoints.split(', ').uniq
        default_htg_sp = UnitConversions.convert(htg_weekend_setpoints.split(', ').uniq[0].to_f, 'F', 'C')
      else
        fail 'Unexpected heating setpoints.'
      end
      if clg_weekday_setpoints.split(', ').uniq.size == 1 && clg_weekend_setpoints.split(', ').uniq.size == 1 && clg_weekday_setpoints.split(', ').uniq == clg_weekend_setpoints.split(', ').uniq
        default_clg_sp = UnitConversions.convert(clg_weekend_setpoints.split(', ').uniq[0].to_f, 'F', 'C')
      else
        fail 'Unexpected cooling setpoints.'
      end
      vent_program.addLine("Set Tnvsp = (#{default_htg_sp} + #{default_clg_sp}) / 2")
    end
    vent_program.addLine("Set NVavail = #{nv_avail_sensor.name}")
    vent_program.addLine("Set ClgSsnAvail = #{nv_clg_ssn_sensor.name}")
    vent_program.addLine('Set Qnv = 0') # Init
    vent_program.addLine('Set Qwhf = 0') # Init
    vent_program.addLine("Set #{cond_to_zone_flow_rate_actuator.name} = 0") unless whf_zone.nil? # Init
    vent_program.addLine("Set #{whf_elec_actuator.name} = 0") # Init
    infil_constraints = 'If ((Wout < MaxHR) && (Tin > Tout) && (Tin > Tnvsp) && (ClgSsnAvail > 0))'
    if not sensors[:hvac_avail].nil?
      # We are using the availability schedule, but we also constrain the window opening based on temperatures and humidity.
      # We're assuming that if the HVAC is not available, you'd ignore the humidity constraints we normally put on window opening per the old HSP guidance (RH < 70% and w < 0.015).
      # Without, the humidity constraints prevent the window from opening during the entire period even though the sensible cooling would have really helped.
      infil_constraints += "|| ((Tin > Tout) && (Tin > Tnvsp) && (#{sensors[:hvac_avail].name} == 0))"
    end
    vent_program.addLine(infil_constraints)
    vent_program.addLine('  Set WHF_Flow = 0')
    vent_fans[:whf].each do |vent_whf|
      vent_program.addLine("  Set WHF_Flow = WHF_Flow + #{UnitConversions.convert(vent_whf.flow_rate, 'cfm', 'm^3/s')} * #{whf_avail_sensors[vent_whf.id].name}")
    end
    vent_program.addLine('  Set Adj = (Tin-Tnvsp)/(Tin-Tout)')
    vent_program.addLine('  Set Adj = (@Min Adj 1)')
    vent_program.addLine('  Set Adj = (@Max Adj 0)')
    vent_program.addLine('  If (WHF_Flow > 0)') # If available, prioritize whole house fan
    vent_program.addLine('    Set Qwhf = WHF_Flow*Adj')
    vent_program.addLine("    Set #{cond_to_zone_flow_rate_actuator.name} = WHF_Flow*Adj") unless whf_zone.nil?
    vent_program.addLine('    Set WHF_W = 0')
    vent_fans[:whf].each do |vent_whf|
      vent_program.addLine("    Set WHF_W = WHF_W + #{vent_whf.fan_power} * #{whf_avail_sensors[vent_whf.id].name}")
    end
    vent_program.addLine("    Set #{whf_elec_actuator.name} = WHF_W*Adj")
    vent_program.addLine('  ElseIf (NVavail > 0)') # Natural ventilation
    vent_program.addLine("    Set NVArea = #{UnitConversions.convert(area, 'ft^2', 'cm^2')}")
    vent_program.addLine("    Set Cs = #{UnitConversions.convert(c_s, 'ft^2/(s^2*R)', 'L^2/(s^2*cm^4*K)')}")
    vent_program.addLine("    Set Cw = #{c_w * 0.01}")
    vent_program.addLine('    Set Tdiff = Tin-Tout')
    vent_program.addLine('    Set dT = (@Abs Tdiff)')
    vent_program.addLine("    Set Vwind = #{sensors[:v_wind].name}")
    vent_program.addLine('    Set SGNV = NVArea*Adj*((((Cs*dT)+(Cw*(Vwind^2)))^0.5)/1000)')
    vent_program.addLine("    Set MaxNV = #{UnitConversions.convert(max_flow_rate, 'cfm', 'm^3/s')}")
    vent_program.addLine('    Set Qnv = (@Min SGNV MaxNV)')
    vent_program.addLine('  EndIf')
    vent_program.addLine('EndIf')
    vent_program.addLine("Set #{nv_flow_actuator.name} = Qnv")
    vent_program.addLine("Set #{whf_flow_actuator.name} = Qwhf")

    manager = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
    manager.setName("#{vent_program.name} calling manager")
    manager.setCallingPoint('BeginZoneTimestepAfterInitHeatBalance')
    manager.addProgram(vent_program)

    # EMS global variables for output reporting
    q_nv_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{vent_program.name}_Qnv")
    q_whf_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{vent_program.name}_Qwhf")
    q_nv_var.additionalProperties.setFeature('ObjectType', Constants::ObjectTypeNaturalVentilation)
    q_whf_var.additionalProperties.setFeature('ObjectType', Constants::ObjectTypeWholeHouseFan)
    vent_program.addLine("Set #{q_nv_var.name} = Qnv")
    vent_program.addLine("Set #{q_whf_var.name} = Qwhf")
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param obj_name [String] Name for the OpenStudio object
  # @param num_days_per_week [TODO] TODO
  # @param unavailable_periods [HPXML::UnavailablePeriods] Object that defines periods for, e.g., power outages or vacancies
  # @return [TODO] TODO
  def self.create_nv_and_whf_avail_sch(model, obj_name, num_days_per_week, unavailable_periods)
    avail_sch = OpenStudio::Model::ScheduleRuleset.new(model)
    sch_name = "#{obj_name} schedule"
    avail_sch.setName(sch_name)
    avail_sch.defaultDaySchedule.setName("#{sch_name} default day")
    Schedule.set_schedule_type_limits(model, avail_sch, EPlus::ScheduleTypeLimitsOnOff)
    on_rule = OpenStudio::Model::ScheduleRule.new(avail_sch)
    on_rule.setName("#{sch_name} rule")
    on_rule_day = on_rule.daySchedule
    on_rule_day.setName("#{sch_name} avail day")
    on_rule_day.addValue(OpenStudio::Time.new(0, 24, 0, 0), 1)
    method_array = ['setApplyMonday', 'setApplyWednesday', 'setApplyFriday', 'setApplySaturday', 'setApplyTuesday', 'setApplyThursday', 'setApplySunday']
    for i in 1..7 do
      if num_days_per_week >= i
        on_rule.public_send(method_array[i - 1], true)
      end
    end
    on_rule.setStartDate(OpenStudio::Date::fromDayOfYear(1))
    on_rule.setEndDate(OpenStudio::Date::fromDayOfYear(365))

    year = model.getYearDescription.assumedYear
    Schedule.set_unavailable_periods(avail_sch, sch_name, unavailable_periods, year)
    return avail_sch
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param loop_name [TODO] TODO
  # @param unit_multiplier [Integer] Number of similar dwelling units
  # @param adiabatic_const [TODO] TODO
  # @return [TODO] TODO
  def self.create_return_air_duct_zone(model, loop_name, unit_multiplier, adiabatic_const)
    # Create the return air plenum zone, space
    ra_duct_zone = OpenStudio::Model::ThermalZone.new(model)
    ra_duct_zone.setMultiplier(unit_multiplier)
    ra_duct_zone.setName(loop_name + ' ret air zone')
    ra_duct_zone.setVolume(1.0)

    ra_duct_polygon = OpenStudio::Point3dVector.new
    ra_duct_polygon << OpenStudio::Point3d.new(0, 0, 0)
    ra_duct_polygon << OpenStudio::Point3d.new(0, 1.0, 0)
    ra_duct_polygon << OpenStudio::Point3d.new(1.0, 1.0, 0)
    ra_duct_polygon << OpenStudio::Point3d.new(1.0, 0, 0)

    ra_space = OpenStudio::Model::Space::fromFloorPrint(ra_duct_polygon, 1, model)
    ra_space = ra_space.get
    ra_space.setName(loop_name + ' ret air space')
    ra_space.setThermalZone(ra_duct_zone)

    ra_space.surfaces.each do |surface|
      if adiabatic_const.nil?
        adiabatic_mat = OpenStudio::Model::MasslessOpaqueMaterial.new(model, 'Rough', 176.1)
        adiabatic_mat.setName('Adiabatic')

        adiabatic_const = OpenStudio::Model::Construction.new(model)
        adiabatic_const.setName('AdiabaticConst')
        adiabatic_const.insertLayer(0, adiabatic_mat)
      end

      surface.setConstruction(adiabatic_const)
      surface.setOutsideBoundaryCondition(EPlus::BoundaryConditionAdiabatic)
      surface.setSunExposure(EPlus::SurfaceSunExposureNo)
      surface.setWindExposure(EPlus::SurfaceWindExposureNo)
      surface_property_convection_coefficients = OpenStudio::Model::SurfacePropertyConvectionCoefficients.new(surface)
      surface_property_convection_coefficients.setConvectionCoefficient1Location('Inside')
      surface_property_convection_coefficients.setConvectionCoefficient1Type('Value')
      surface_property_convection_coefficients.setConvectionCoefficient1(30)
    end

    return ra_duct_zone, adiabatic_const
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param name [TODO] TODO
  # @param space [OpenStudio::Model::Space] an OpenStudio::Model::Space object
  # @param frac_lat [TODO] TODO
  # @param frac_lost [TODO] TODO
  # @param hpxml_fuel_type [String] HPXML fuel type (HPXML::FuelTypeXXX)
  # @param end_use [TODO] TODO
  # @return [TODO] TODO
  def self.create_other_equipment_object_and_actuator(model:, name:, space:, frac_lat:, frac_lost:, hpxml_fuel_type: nil, end_use: nil)
    other_equip_def = OpenStudio::Model::OtherEquipmentDefinition.new(model)
    other_equip_def.setName("#{name} equip")
    other_equip = OpenStudio::Model::OtherEquipment.new(other_equip_def)
    other_equip.setName(other_equip_def.name.to_s)
    other_equip.setFuelType(EPlus.fuel_type(hpxml_fuel_type))
    if not end_use.nil?
      other_equip.setEndUseSubcategory(end_use)
    end
    other_equip.setSchedule(model.alwaysOnDiscreteSchedule)
    other_equip.setSpace(space)
    other_equip_def.setFractionLost(frac_lost)
    other_equip_def.setFractionLatent(frac_lat)
    other_equip_def.setFractionRadiant(0.0)
    actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(other_equip, *EPlus::EMSActuatorOtherEquipmentPower, other_equip.space.get)
    actuator.setName("#{other_equip.name} act")
    return actuator
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param vent_fans [TODO] TODO
  # @param airloop_map [Hash] Map of HPXML System ID => OpenStudio AirLoopHVAC (or ZoneHVACFourPipeFanCoil or ZoneHVACBaseboardConvectiveWater) objects
  # @param unavailable_periods [HPXML::UnavailablePeriods] Object that defines periods for, e.g., power outages or vacancies
  # @return [TODO] TODO
  def self.initialize_cfis(model, vent_fans, airloop_map, unavailable_periods)
    cfis_data = { airloop: {}, t_sum_open_var: {}, f_damper_extra_open_var: {} }
    return cfis_data if vent_fans[:mech].empty?

    index = 0

    vent_fans[:mech].each do |vent_mech|
      next if vent_mech.fan_type != HPXML::MechVentTypeCFIS

      fail 'Cannot apply unavailable period(s) to CFIS systems.' if !unavailable_periods.empty?

      # Get AirLoop associated with CFIS
      vent_mech.distribution_system.hvac_systems.map { |system| system.id }.each do |cfis_id|
        next if airloop_map[cfis_id].nil?

        cfis_data[:airloop][vent_mech.id] = airloop_map[cfis_id]
      end

      cfis_data[:t_sum_open_var][vent_mech.id] = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{Constants::ObjectTypeMechanicalVentilation.gsub(' ', '_')}_cfis_t_sum_open_#{index}") # Sums the time during an hour the CFIS damper has been open
      cfis_data[:f_damper_extra_open_var][vent_mech.id] = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{Constants::ObjectTypeMechanicalVentilation.gsub(' ', '_')}_cfis_f_extra_damper_open_#{index}") # Fraction of timestep the CFIS blower is running while hvac is not operating. Used by infiltration and duct leakage programs

      # CFIS Initialization Program
      cfis_program = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
      cfis_program.setName(Constants::ObjectTypeMechanicalVentilation + " cfis init program #{index}")
      cfis_program.addLine("Set #{cfis_data[:t_sum_open_var][vent_mech.id].name} = 0")
      cfis_program.addLine("Set #{cfis_data[:f_damper_extra_open_var][vent_mech.id].name} = 0")

      manager = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
      manager.setName("#{cfis_program.name} calling manager")
      manager.setCallingPoint('BeginNewEnvironment')
      manager.addProgram(cfis_program)

      manager = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
      manager.setName("#{cfis_program.name} calling manager2")
      manager.setCallingPoint('AfterNewEnvironmentWarmUpIsComplete')
      manager.addProgram(cfis_program)

      index += 1
    end

    return cfis_data
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param osm_object [TODO] TODO
  # @param fan_data [TODO] TODO
  # @return [TODO] TODO
  def self.initialize_fan_objects(model, osm_object, fan_data)
    # Get the supply fan
    if osm_object.is_a? OpenStudio::Model::ZoneHVACFourPipeFanCoil
      supply_fan = osm_object.supplyAirFan
    elsif osm_object.is_a? OpenStudio::Model::AirLoopHVAC
      system = HVAC.get_unitary_system_from_air_loop_hvac(osm_object)
      if system.nil? # Evaporative cooler supply fan directly on air loop
        supply_fan = osm_object.supplyFan.get
      else
        supply_fan = system.supplyFan.get
      end
    else
      fail 'Unexpected object type.'
    end

    fan_data[:rtf_var][osm_object] = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{osm_object.name} Fan RTF".gsub(' ', '_'))

    # Supply fan maximum mass flow rate
    fan_data[:mfr_max_var][osm_object] = OpenStudio::Model::EnergyManagementSystemInternalVariable.new(model, EPlus::EMSIntVarFanMFR)
    fan_data[:mfr_max_var][osm_object].setName("#{osm_object.name} max sup fan mfr")
    fan_data[:mfr_max_var][osm_object].setInternalDataIndexKeyName(supply_fan.name.to_s)

    if supply_fan.to_FanSystemModel.is_initialized
      fan_data[:rtf_sensor][osm_object] = []
      num_speeds = supply_fan.to_FanSystemModel.get.numberofSpeeds
      for i in 1..num_speeds
        if num_speeds == 1
          var_name = 'Fan Runtime Fraction'
        else
          var_name = "Fan Runtime Fraction Speed #{i}"
        end
        rtf_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, var_name)
        rtf_sensor.setName("#{fan_data[:rtf_var][osm_object].name} s")
        rtf_sensor.setKeyName(supply_fan.name.to_s)
        fan_data[:rtf_sensor][osm_object] << rtf_sensor
      end
    else
      fail "Unexpected fan: #{supply_fan.name}"
    end
  end

  # TODO
  #
  # @param runner [OpenStudio::Measure::OSRunner] Object typically used to display warnings
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [nil]
  def self.check_duct_leakage(runner, hpxml_bldg)
    # Duct leakage to outside warnings?
    # Need to check here instead of in schematron in case duct locations are defaulted
    cfa = hpxml_bldg.building_construction.conditioned_floor_area
    hpxml_bldg.hvac_distributions.each do |hvac_distribution|
      next unless hvac_distribution.distribution_system_type == HPXML::HVACDistributionTypeAir
      next if hvac_distribution.duct_leakage_measurements.empty?

      units = hvac_distribution.duct_leakage_measurements[0].duct_leakage_units
      lto_measurements = hvac_distribution.duct_leakage_measurements.select { |dlm| dlm.duct_leakage_total_or_to_outside == HPXML::DuctLeakageToOutside }
      sum_lto = lto_measurements.map { |dlm| dlm.duct_leakage_value }.sum(0.0)

      if hvac_distribution.ducts.select { |d| !HPXML::conditioned_locations_this_unit.include?(d.duct_location) }.size == 0
        # If ducts completely in conditioned space, issue warning if duct leakage to outside above a certain threshold (e.g., 5%)
        issue_warning = false
        if units == HPXML::UnitsCFM25
          issue_warning = true if sum_lto > 0.04 * cfa
        elsif units == HPXML::UnitsCFM50
          issue_warning = true if sum_lto > 0.06 * cfa
        elsif units == HPXML::UnitsPercent
          issue_warning = true if sum_lto > 0.05
        end
        next unless issue_warning

        runner.registerWarning('Ducts are entirely within conditioned space but there is moderate leakage to the outside. Leakage to the outside is typically zero or near-zero in these situations, consider revising leakage values. Leakage will be modeled as heat lost to the ambient environment.')
      else
        # If ducts in unconditioned space, issue warning if duct leakage to outside above a certain threshold (e.g., 40%)
        issue_warning = false
        if units == HPXML::UnitsCFM25
          issue_warning = true if sum_lto >= 0.32 * cfa
        elsif units == HPXML::UnitsCFM50
          issue_warning = true if sum_lto >= 0.48 * cfa
        elsif units == HPXML::UnitsPercent
          issue_warning = true if sum_lto >= 0.4
        end
        next unless issue_warning

        runner.registerWarning('Very high sum of supply + return duct leakage to the outside; double-check inputs.')
      end
    end
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param ducts [TODO] TODO
  # @param object [TODO] TODO
  # @param vent_fans [TODO] TODO
  # @param cfis_data [TODO] TODO
  # @param fan_data [TODO] TODO
  # @param duct_lk_imbals [TODO] TODO
  # @param sensors [Hash] Map of :sensor_types => EMS sensors
  # @param adiabatic_const [TODO] TODO
  # @return [TODO] TODO
  def self.apply_ducts(model, spaces, hpxml_bldg, ducts, object, vent_fans, cfis_data, fan_data, duct_lk_imbals, sensors, adiabatic_const)
    conditioned_space = spaces[HPXML::LocationConditionedSpace]
    conditioned_zone = conditioned_space.thermalZone.get
    unit_multiplier = hpxml_bldg.building_construction.number_of_units

    ducts.each do |duct|
      if not duct.loc_schedule.nil?
        # Pass MF space temperature schedule name
        duct.location = duct.loc_schedule.name.to_s
      elsif not duct.loc_space.nil?
        duct.location = duct.loc_space.name.to_s
        duct.zone = duct.loc_space.thermalZone.get
      else # Outside/RoofDeck
        duct.location = HPXML::LocationOutside
        duct.zone = nil
      end
    end

    return if ducts.size == 0 # No ducts

    if object.is_a? OpenStudio::Model::AirLoopHVAC
      # Most system types

      # Set the return plenum
      ra_duct_zone, adiabatic_const = create_return_air_duct_zone(model, object.name.to_s, unit_multiplier, adiabatic_const)
      ra_duct_space = ra_duct_zone.spaces[0]
      conditioned_zone.setReturnPlenum(ra_duct_zone, object)

      inlet_node = object.demandInletNode
    elsif object.is_a? OpenStudio::Model::ZoneHVACFourPipeFanCoil
      # Ducted fan coil

      # No return plenum
      ra_duct_space = conditioned_space

      inlet_node = object.inletNode.get
    end

    # -- Sensors --

    # Air handler mass flow rate
    ah_mfr_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{object.name} AH MFR".gsub(' ', '_'))
    ah_mfr_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'System Node Mass Flow Rate')
    ah_mfr_sensor.setName("#{ah_mfr_var.name} s")
    ah_mfr_sensor.setKeyName(inlet_node.name.to_s)

    # Air handler volume flow rate
    ah_vfr_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{object.name} AH VFR".gsub(' ', '_'))
    ah_vfr_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'System Node Current Density Volume Flow Rate')
    ah_vfr_sensor.setName("#{ah_vfr_var.name} s")
    ah_vfr_sensor.setKeyName(inlet_node.name.to_s)

    # Air handler outlet temperature
    ah_tout_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{object.name} AH Tout".gsub(' ', '_'))
    ah_tout_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'System Node Temperature')
    ah_tout_sensor.setName("#{ah_tout_var.name} s")
    ah_tout_sensor.setKeyName(inlet_node.name.to_s)

    # Air handler outlet humidity ratio
    ah_wout_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{object.name} AH Wout".gsub(' ', '_'))
    ah_wout_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'System Node Humidity Ratio')
    ah_wout_sensor.setName("#{ah_wout_var.name} s")
    ah_wout_sensor.setKeyName(inlet_node.name.to_s)

    conditioned_zone_return_air_node = nil
    conditioned_zone.returnAirModelObjects.each do |return_air_model_obj|
      next if return_air_model_obj.to_Node.get.airLoopHVAC.get != object

      conditioned_zone_return_air_node = return_air_model_obj
    end

    # Return air temperature
    ra_t_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{object.name} RA T".gsub(' ', '_'))
    if not conditioned_zone_return_air_node.nil?
      ra_t_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'System Node Temperature')
      ra_t_sensor.setName("#{ra_t_var.name} s")
      ra_t_sensor.setKeyName(conditioned_zone_return_air_node.name.to_s)
    else
      ra_t_sensor = sensors[:t_in]
    end

    # Return air humidity ratio
    ra_w_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{object.name} Ra W".gsub(' ', '_'))
    if not conditioned_zone_return_air_node.nil?
      ra_w_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'System Node Humidity Ratio')
      ra_w_sensor.setName("#{ra_w_var.name} s")
      ra_w_sensor.setKeyName(conditioned_zone_return_air_node.name.to_s)
    else
      ra_w_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Zone Mean Air Humidity Ratio')
      ra_w_sensor.setName("#{ra_w_var.name} s")
      ra_w_sensor.setKeyName(conditioned_zone.name.to_s)
    end

    # Get duct located zone or ambient temperature schedule objects
    duct_locations = ducts.map { |duct| if duct.zone.nil? then duct.loc_schedule else duct.zone end }.uniq

    # Create one duct program for each duct location zone
    duct_locations.each_with_index do |duct_location, i|
      next if (not duct_location.nil?) && (duct_location.name.to_s == conditioned_zone.name.to_s)

      object_name_idx = "#{object.name}_#{i}"

      # -- Sensors --

      # Duct zone temperature
      dz_t_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{object_name_idx} DZ T".gsub(' ', '_'))
      if duct_location.is_a? OpenStudio::Model::ThermalZone
        dz_t_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Zone Air Temperature')
        dz_t_sensor.setKeyName(duct_location.name.to_s)
      elsif duct_location.is_a? OpenStudio::Model::ScheduleConstant
        dz_t_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Schedule Value')
        dz_t_sensor.setKeyName(duct_location.name.to_s)
      elsif duct_location.nil? # Outside
        dz_t_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Site Outdoor Air Drybulb Temperature')
        dz_t_sensor.setKeyName('Environment')
      else # shouldn't get here, should only have schedule/thermal zone/nil assigned
        fail 'Unexpected duct zone type passed'
      end
      dz_t_sensor.setName("#{dz_t_var.name} s")

      # Duct zone humidity ratio
      dz_w_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{object_name_idx} DZ W".gsub(' ', '_'))
      if duct_location.is_a? OpenStudio::Model::ThermalZone
        dz_w_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Zone Mean Air Humidity Ratio')
        dz_w_sensor.setKeyName(duct_location.name.to_s)
        dz_w_sensor.setName("#{dz_w_var.name} s")
        dz_w = "#{dz_w_sensor.name}"
      elsif duct_location.is_a? OpenStudio::Model::ScheduleConstant # Outside or scheduled temperature
        if duct_location.name.to_s == HPXML::LocationOtherNonFreezingSpace
          dz_w_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Site Outdoor Air Humidity Ratio')
          dz_w_sensor.setName("#{dz_w_var.name} s")
          dz_w = "#{dz_w_sensor.name}"
        elsif duct_location.name.to_s == HPXML::LocationOtherHousingUnit
          dz_w_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Zone Mean Air Humidity Ratio')
          dz_w_sensor.setKeyName(conditioned_zone.name.to_s)
          dz_w_sensor.setName("#{dz_w_var.name} s")
          dz_w = "#{dz_w_sensor.name}"
        else
          dz_w_sensor1 = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Site Outdoor Air Humidity Ratio')
          dz_w_sensor1.setName("#{dz_w_var.name} s 1")
          dz_w_sensor2 = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Zone Mean Air Humidity Ratio')
          dz_w_sensor2.setName("#{dz_w_var.name} s 2")
          dz_w_sensor2.setKeyName(conditioned_zone.name.to_s)
          dz_w = "(#{dz_w_sensor1.name} + #{dz_w_sensor2.name}) / 2"
        end
      else
        dz_w_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Site Outdoor Air Humidity Ratio')
        dz_w_sensor.setName("#{dz_w_var.name} s")
        dz_w = "#{dz_w_sensor.name}"
      end

      # -- Actuators --

      # List of: [Var name, object name, space, frac load latent, frac load outside]
      equip_act_infos = []

      if duct_location.is_a? OpenStudio::Model::ScheduleConstant
        space_values = Geometry.get_temperature_scheduled_space_values(duct_location.name.to_s)
        f_regain = space_values[:f_regain]
      else
        f_regain = 0.0
      end

      # Other equipment objects to cancel out the supply air leakage directly into the return plenum
      equip_act_infos << ['supply_sens_lk_to_cond', 'SupSensLkToCond', Constants::ObjectTypeDuctLoad, conditioned_space, 0.0, f_regain]
      equip_act_infos << ['supply_lat_lk_to_cond', 'SupLatLkToCond', Constants::ObjectTypeDuctLoad, conditioned_space, 1.0 - f_regain, f_regain]

      # Supply duct conduction load added to the conditioned space
      equip_act_infos << ['supply_cond_to_cond', 'SupCondToLv', Constants::ObjectTypeDuctLoad, conditioned_space, 0.0, f_regain]

      # Return duct conduction load added to the return plenum zone
      equip_act_infos << ['return_cond_to_rp', 'RetCondToRP', Constants::ObjectTypeDuctLoad, ra_duct_space, 0.0, f_regain]

      # Return duct sensible leakage impact on the return plenum
      equip_act_infos << ['return_sens_lk_to_rp', 'RetSensLkToRP', Constants::ObjectTypeDuctLoad, ra_duct_space, 0.0, f_regain]

      # Return duct latent leakage impact on the return plenum
      equip_act_infos << ['return_lat_lk_to_rp', 'RetLatLkToRP', Constants::ObjectTypeDuctLoad, ra_duct_space, 1.0 - f_regain, f_regain]

      # Supply duct conduction impact on the duct zone
      if not duct_location.is_a? OpenStudio::Model::ThermalZone # Outside or scheduled temperature
        equip_act_infos << ['supply_cond_to_dz', 'SupCondToDZ', nil, conditioned_space, 0.0, 1.0] # Arbitrary space, all heat lost
      else
        equip_act_infos << ['supply_cond_to_dz', 'SupCondToDZ', nil, duct_location.spaces[0], 0.0, 0.0]
      end

      # Return duct conduction impact on the duct zone
      if not duct_location.is_a? OpenStudio::Model::ThermalZone # Outside or scheduled temperature
        equip_act_infos << ['return_cond_to_dz', 'RetCondToDZ', nil, conditioned_space, 0.0, 1.0] # Arbitrary space, all heat lost
      else
        equip_act_infos << ['return_cond_to_dz', 'RetCondToDZ', nil, duct_location.spaces[0], 0.0, 0.0]
      end

      # Supply duct sensible leakage impact on the duct zone
      if not duct_location.is_a? OpenStudio::Model::ThermalZone # Outside or scheduled temperature
        equip_act_infos << ['supply_sens_lk_to_dz', 'SupSensLkToDZ', nil, conditioned_space, 0.0, 1.0] # Arbitrary space, all heat lost
      else
        equip_act_infos << ['supply_sens_lk_to_dz', 'SupSensLkToDZ', nil, duct_location.spaces[0], 0.0, 0.0]
      end

      # Supply duct latent leakage impact on the duct zone
      if not duct_location.is_a? OpenStudio::Model::ThermalZone # Outside or scheduled temperature
        equip_act_infos << ['supply_lat_lk_to_dz', 'SupLatLkToDZ', nil, conditioned_space, 0.0, 1.0] # Arbitrary space, all heat lost
      else
        equip_act_infos << ['supply_lat_lk_to_dz', 'SupLatLkToDZ', nil, duct_location.spaces[0], 1.0, 0.0]
      end

      duct_vars = {}
      duct_actuators = {}
      [false, true].each do |is_cfis|
        if is_cfis
          next unless cfis_data[:airloop].values.include? object

          prefix = 'cfis_'
        else
          prefix = ''
        end
        equip_act_infos.each do |act_info|
          var_name = "#{prefix}#{act_info[0]}"
          object_name = "#{object_name_idx} #{prefix}#{act_info[1]}".gsub(' ', '_')
          end_use = act_info[2]
          space = act_info[3]
          if is_cfis && (space == ra_duct_space)
            # Move all CFIS return duct losses to the conditioned space so as to avoid extreme plenum temperatures
            # due to mismatch between return plenum duct loads and airloop airflow rate (which does not actually
            # increase due to the presence of CFIS).
            space = conditioned_space
          end
          frac_lat = act_info[4]
          frac_lost = act_info[5]
          if not is_cfis
            duct_vars[var_name] = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, object_name)
          end
          duct_actuators[var_name] = create_other_equipment_object_and_actuator(model: model, name: object_name, space: space, frac_lat: frac_lat, frac_lost: frac_lost, end_use: end_use)
        end
      end

      # Two objects are required to model the air exchange between the duct zone and the conditioned space since
      # ZoneMixing objects can not account for direction of air flow (both are controlled by EMS)

      # List of: [Var name, object name, space, frac load latent, frac load outside]
      mix_act_infos = []

      if duct_location.is_a? OpenStudio::Model::ThermalZone
        # Accounts for leaks from the duct zone to the conditioned zone
        mix_act_infos << ['dz_to_cond_flow_rate', 'ZoneMixDZToCond', conditioned_zone, duct_location]
        # Accounts for leaks from the conditioned zone to the duct zone
        mix_act_infos << ['cond_to_dz_flow_rate', 'ZoneMixCondToDZ', duct_location, conditioned_zone]
      end

      [false, true].each do |is_cfis|
        if is_cfis
          next unless cfis_data[:airloop].values.include? object

          prefix = 'cfis_'
        else
          prefix = ''
        end
        mix_act_infos.each do |act_info|
          var_name = "#{prefix}#{act_info[0]}"
          object_name = "#{object_name_idx} #{prefix}#{act_info[1]}".gsub(' ', '_')
          dest_zone = act_info[2]
          source_zone = act_info[3]

          if not is_cfis
            duct_vars[var_name] = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, object_name)
          end
          zone_mixing = OpenStudio::Model::ZoneMixing.new(dest_zone)
          zone_mixing.setName("#{object_name} mix")
          zone_mixing.setSourceZone(source_zone)
          duct_actuators[var_name] = OpenStudio::Model::EnergyManagementSystemActuator.new(zone_mixing, *EPlus::EMSActuatorZoneMixingFlowRate)
          duct_actuators[var_name].setName("#{zone_mixing.name} act")
          zone_mixing.additionalProperties.setFeature('ObjectType', Constants::ObjectTypeDuctLoad)
        end
      end

      # -- Global Variables --
      duct_lk_supply_fan_equiv_cond_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{object_name_idx} DuctImbalLkSupFanEquivCond".gsub(' ', '_'))
      duct_lk_exhaust_fan_equiv_cond_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{object_name_idx} DuctImbalLkExhFanEquivCond".gsub(' ', '_'))
      duct_lk_imbals << [conditioned_zone.name.to_s, duct_lk_supply_fan_equiv_cond_var, duct_lk_exhaust_fan_equiv_cond_var]
      if not duct_location.nil?
        duct_lk_supply_fan_equiv_dz_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{object_name_idx} DuctImbalLkSupFanEquivDZ".gsub(' ', '_'))
        duct_lk_exhaust_fan_equiv_dz_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{object_name_idx} DuctImbalLkExhFanEquivDZ".gsub(' ', '_'))
        duct_lk_imbals << [duct_location.name.to_s, duct_lk_supply_fan_equiv_dz_var, duct_lk_exhaust_fan_equiv_dz_var]
      end

      # Obtain aggregate values for all ducts in the current duct location
      leakage_fracs = { HPXML::DuctTypeSupply => nil, HPXML::DuctTypeReturn => nil }
      leakage_cfm25s = { HPXML::DuctTypeSupply => nil, HPXML::DuctTypeReturn => nil }
      ua_values = { HPXML::DuctTypeSupply => 0, HPXML::DuctTypeReturn => 0 }
      ducts.each do |duct|
        next unless (duct_location.nil? && duct.zone.nil?) ||
                    (!duct_location.nil? && !duct.zone.nil? && (duct.zone.name.to_s == duct_location.name.to_s)) ||
                    (!duct_location.nil? && !duct.loc_schedule.nil? && (duct.loc_schedule.name.to_s == duct_location.name.to_s))

        if not duct.leakage_frac.nil?
          leakage_fracs[duct.side] = 0 if leakage_fracs[duct.side].nil?
          leakage_fracs[duct.side] += duct.leakage_frac
        elsif not duct.leakage_cfm25.nil?
          leakage_cfm25s[duct.side] = 0 if leakage_cfm25s[duct.side].nil?
          leakage_cfm25s[duct.side] += duct.leakage_cfm25
        elsif not duct.leakage_cfm50.nil?
          leakage_cfm25s[duct.side] = 0 if leakage_cfm25s[duct.side].nil?
          leakage_cfm25s[duct.side] += calc_air_leakage_at_diff_pressure(InfilPressureExponent, duct.leakage_cfm50, 50.0, 25.0)
        end
        ua_values[duct.side] += duct.area / duct.effective_rvalue
      end

      # Check if the duct location is a vented space
      duct_location_is_vented = false
      if duct_location.is_a? OpenStudio::Model::ThermalZone
        HPXML::vented_locations.each do |vented_location|
          if (not spaces[vented_location].nil?) && (spaces[vented_location].thermalZone.get.name.to_s == duct_location.name.to_s)
            duct_location_is_vented = true
          end
        end
      end

      # Duct Subroutine
      duct_subroutine = OpenStudio::Model::EnergyManagementSystemSubroutine.new(model)
      duct_subroutine.setName("#{object_name_idx} duct subroutine")
      duct_subroutine.addLine("Set AH_MFR = #{ah_mfr_var.name} / #{unit_multiplier}")
      duct_subroutine.addLine('If AH_MFR > 0')
      duct_subroutine.addLine("  Set AH_Tout = #{ah_tout_var.name}")
      duct_subroutine.addLine("  Set AH_Wout = #{ah_wout_var.name}")
      duct_subroutine.addLine("  Set RA_T = #{ra_t_var.name}")
      duct_subroutine.addLine("  Set RA_W = #{ra_w_var.name}")
      duct_subroutine.addLine("  Set Fan_RTF = #{fan_data[:rtf_var][object].name}")
      duct_subroutine.addLine("  Set DZ_T = #{dz_t_var.name}")
      duct_subroutine.addLine("  Set DZ_W = #{dz_w_var.name}")
      duct_subroutine.addLine("  Set AH_VFR = #{ah_vfr_var.name} / #{unit_multiplier}")
      duct_subroutine.addLine('  Set h_SA = (@HFnTdbW AH_Tout AH_Wout)') # J/kg
      duct_subroutine.addLine('  Set h_RA = (@HFnTdbW RA_T RA_W)') # J/kg
      duct_subroutine.addLine('  Set h_fg = (@HfgAirFnWTdb AH_Wout AH_Tout)') # J/kg
      duct_subroutine.addLine('  Set h_DZ = (@HFnTdbW DZ_T DZ_W)') # J/kg
      duct_subroutine.addLine('  Set air_cp = 1006.0') # J/kg-C

      if not leakage_fracs[HPXML::DuctTypeSupply].nil?
        duct_subroutine.addLine("  Set f_sup = #{leakage_fracs[HPXML::DuctTypeSupply]}") # frac
      elsif not leakage_cfm25s[HPXML::DuctTypeSupply].nil?
        duct_subroutine.addLine("  Set f_sup = #{UnitConversions.convert(leakage_cfm25s[HPXML::DuctTypeSupply], 'cfm', 'm^3/s').round(6)} / (#{fan_data[:mfr_max_var][object].name}/#{unit_multiplier} * 1.0135)") # frac
      else
        duct_subroutine.addLine('  Set f_sup = 0.0') # frac
      end
      if not leakage_fracs[HPXML::DuctTypeReturn].nil?
        duct_subroutine.addLine("  Set f_ret = #{leakage_fracs[HPXML::DuctTypeReturn]}") # frac
      elsif not leakage_cfm25s[HPXML::DuctTypeReturn].nil?
        duct_subroutine.addLine("  Set f_ret = #{UnitConversions.convert(leakage_cfm25s[HPXML::DuctTypeReturn], 'cfm', 'm^3/s').round(6)} / (#{fan_data[:mfr_max_var][object].name}/#{unit_multiplier} * 1.0135)") # frac
      else
        duct_subroutine.addLine('  Set f_ret = 0.0') # frac
      end
      duct_subroutine.addLine('  Set sup_lk_mfr = f_sup * AH_MFR') # kg/s
      duct_subroutine.addLine('  Set ret_lk_mfr = f_ret * AH_MFR') # kg/s

      # Supply leakage to conditioned space
      duct_subroutine.addLine('  Set SupTotLkToCond = sup_lk_mfr*(h_RA - h_SA)') # W
      duct_subroutine.addLine('  Set SupLatLkToCond = sup_lk_mfr*h_fg*(RA_W-AH_Wout)') # W
      duct_subroutine.addLine('  Set SupSensLkToCond = SupTotLkToCond-SupLatLkToCond') # W

      # Supply conduction
      duct_subroutine.addLine("  Set supply_ua = #{UnitConversions.convert(ua_values[HPXML::DuctTypeSupply], 'Btu/(hr*F)', 'W/K').round(3)}")
      duct_subroutine.addLine('  Set eTm = 0-((Fan_RTF/(AH_MFR*air_cp))*supply_ua)')
      duct_subroutine.addLine('  Set t_sup = DZ_T+((AH_Tout-DZ_T)*(@Exp eTm))') # C
      duct_subroutine.addLine('  Set SupCondToCond = AH_MFR*air_cp*(t_sup-AH_Tout)') # W
      duct_subroutine.addLine('  Set SupCondToDZ = 0-SupCondToCond') # W

      # Return conduction
      duct_subroutine.addLine("  Set return_ua = #{UnitConversions.convert(ua_values[HPXML::DuctTypeReturn], 'Btu/(hr*F)', 'W/K').round(3)}")
      duct_subroutine.addLine('  Set eTm = 0-((Fan_RTF/(AH_MFR*air_cp))*return_ua)')
      duct_subroutine.addLine('  Set t_ret = DZ_T+((RA_T-DZ_T)*(@Exp eTm))') # C
      duct_subroutine.addLine('  Set RetCondToRP = AH_MFR*air_cp*(t_ret-RA_T)') # W
      duct_subroutine.addLine('  Set RetCondToDZ = 0-RetCondToRP') # W

      # Return leakage to return plenum
      duct_subroutine.addLine('  Set RetLatLkToRP = 0') # W
      duct_subroutine.addLine('  Set RetSensLkToRP = ret_lk_mfr*air_cp*(DZ_T-RA_T)') # W

      # Supply leakage to duct zone
      # The below terms are not the same as SupLatLkToCond and SupSensLkToCond.
      # To understand why, suppose the AHzone temperature equals the supply air temperature. In this case, the terms below
      # should be zero while SupLatLkToCond and SupSensLkToCond should still be non-zero.
      duct_subroutine.addLine('  Set SupTotLkToDZ = sup_lk_mfr*(h_SA-h_DZ)') # W
      duct_subroutine.addLine('  Set SupLatLkToDZ = sup_lk_mfr*h_fg*(AH_Wout-DZ_W)') # W
      duct_subroutine.addLine('  Set SupSensLkToDZ = SupTotLkToDZ-SupLatLkToDZ') # W

      # Handle duct leakage imbalance induced infiltration (ANSI 301-2022 Addendum C Table 4.2.2(1c)
      leakage_supply = leakage_fracs[HPXML::DuctTypeSupply].to_f + leakage_cfm25s[HPXML::DuctTypeSupply].to_f
      leakage_return = leakage_fracs[HPXML::DuctTypeReturn].to_f + leakage_cfm25s[HPXML::DuctTypeReturn].to_f
      if leakage_supply == leakage_return
        duct_subroutine.addLine('  Set FracOutsideToCond = 0.0')
        duct_subroutine.addLine('  Set FracOutsideToDZ = 0.0')
        duct_subroutine.addLine('  Set FracCondToOutside = 0.0')
        duct_subroutine.addLine('  Set FracDZToOutside = 0.0')
        duct_subroutine.addLine('  Set FracDZToCond = 0.0')
        duct_subroutine.addLine('  Set FracCondToDZ = 0.0')
      elsif leakage_supply > leakage_return # Supply > Return (conditioned space is depressurized)
        if duct_location_is_vented # Duct location vented
          duct_subroutine.addLine('  Set FracOutsideToCond = 1.0')
          duct_subroutine.addLine('  Set FracOutsideToDZ = 0.0')
          duct_subroutine.addLine('  Set FracCondToOutside = 0.0')
          duct_subroutine.addLine('  Set FracDZToOutside = 1.0')
          duct_subroutine.addLine('  Set FracDZToCond = 0.0')
          duct_subroutine.addLine('  Set FracCondToDZ = 0.0')
        else # Duct location unvented
          duct_subroutine.addLine('  Set FracOutsideToCond = 0.5')
          duct_subroutine.addLine('  Set FracOutsideToDZ = 0.0')
          duct_subroutine.addLine('  Set FracCondToOutside = 0.0')
          duct_subroutine.addLine('  Set FracDZToOutside = 0.5')
          duct_subroutine.addLine('  Set FracDZToCond = 0.5')
          duct_subroutine.addLine('  Set FracCondToDZ = 0.0')
        end
      else # Supply < Return (conditioned space is pressurized)
        if duct_location_is_vented # Duct location vented
          duct_subroutine.addLine('  Set FracOutsideToCond = 0.0')
          duct_subroutine.addLine('  Set FracOutsideToDZ = 1.0')
          duct_subroutine.addLine('  Set FracCondToOutside = 1.0')
          duct_subroutine.addLine('  Set FracDZToOutside = 0.0')
          duct_subroutine.addLine('  Set FracDZToCond = 0.0')
          duct_subroutine.addLine('  Set FracCondToDZ = 0.0')
        else # Duct location unvented
          duct_subroutine.addLine('  Set FracOutsideToCond = 0.0')
          duct_subroutine.addLine('  Set FracOutsideToDZ = 0.5')
          duct_subroutine.addLine('  Set FracCondToOutside = 0.5')
          duct_subroutine.addLine('  Set FracDZToOutside = 0.0')
          duct_subroutine.addLine('  Set FracDZToCond = 0.0')
          duct_subroutine.addLine('  Set FracCondToDZ = 0.5')
        end
      end
      duct_subroutine.addLine('  Set lk_imbal_vfr = @ABS(f_sup - f_ret) * AH_VFR') # m3/s
      duct_subroutine.addLine('  Set ImbalLkCondToDZ = lk_imbal_vfr * FracCondToDZ') # m3/s
      duct_subroutine.addLine('  Set ImbalLkDZToCond = lk_imbal_vfr * FracDZToCond') # m3/s
      duct_subroutine.addLine('  Set ImbalLkOutsideToCond = lk_imbal_vfr * FracOutsideToCond') # m3/s
      duct_subroutine.addLine('  Set ImbalLkOutsideToDZ = lk_imbal_vfr * FracOutsideToDZ') # m3/s
      duct_subroutine.addLine('  Set ImbalLkCondToOutside = lk_imbal_vfr * FracCondToOutside') # m3/s
      duct_subroutine.addLine('  Set ImbalLkDZToOutside = lk_imbal_vfr * FracDZToOutside') # m3/s
      duct_subroutine.addLine('Else') # No air handler flow rate
      duct_subroutine.addLine('  Set SupLatLkToCond = 0')
      duct_subroutine.addLine('  Set SupSensLkToCond = 0')
      duct_subroutine.addLine('  Set SupCondToCond = 0')
      duct_subroutine.addLine('  Set RetCondToRP = 0')
      duct_subroutine.addLine('  Set RetLatLkToRP = 0')
      duct_subroutine.addLine('  Set RetSensLkToRP = 0')
      duct_subroutine.addLine('  Set RetCondToDZ = 0')
      duct_subroutine.addLine('  Set SupCondToDZ = 0')
      duct_subroutine.addLine('  Set SupLatLkToDZ = 0')
      duct_subroutine.addLine('  Set SupSensLkToDZ = 0')
      duct_subroutine.addLine('  Set ImbalLkCondToDZ = 0')
      duct_subroutine.addLine('  Set ImbalLkDZToCond = 0')
      duct_subroutine.addLine('  Set ImbalLkOutsideToCond = 0')
      duct_subroutine.addLine('  Set ImbalLkOutsideToDZ = 0')
      duct_subroutine.addLine('  Set ImbalLkCondToOutside = 0')
      duct_subroutine.addLine('  Set ImbalLkDZToOutside = 0')
      duct_subroutine.addLine('EndIf')
      duct_subroutine.addLine("Set #{duct_vars['supply_lat_lk_to_cond'].name} = SupLatLkToCond")
      duct_subroutine.addLine("Set #{duct_vars['supply_sens_lk_to_cond'].name} = SupSensLkToCond")
      duct_subroutine.addLine("Set #{duct_vars['supply_cond_to_cond'].name} = SupCondToCond")
      duct_subroutine.addLine("Set #{duct_vars['return_cond_to_rp'].name} = RetCondToRP")
      duct_subroutine.addLine("Set #{duct_vars['return_lat_lk_to_rp'].name} = RetLatLkToRP")
      duct_subroutine.addLine("Set #{duct_vars['return_sens_lk_to_rp'].name} = RetSensLkToRP")
      duct_subroutine.addLine("Set #{duct_vars['return_cond_to_dz'].name} = RetCondToDZ")
      duct_subroutine.addLine("Set #{duct_vars['supply_cond_to_dz'].name} = SupCondToDZ")
      duct_subroutine.addLine("Set #{duct_vars['supply_lat_lk_to_dz'].name} = SupLatLkToDZ")
      duct_subroutine.addLine("Set #{duct_vars['supply_sens_lk_to_dz'].name} = SupSensLkToDZ")
      if duct_location.is_a? OpenStudio::Model::ThermalZone
        duct_subroutine.addLine("Set #{duct_vars['cond_to_dz_flow_rate'].name} = ImbalLkCondToDZ")
        duct_subroutine.addLine("Set #{duct_vars['dz_to_cond_flow_rate'].name} = ImbalLkDZToCond")
      end
      duct_subroutine.addLine("Set #{duct_lk_supply_fan_equiv_cond_var.name} = ImbalLkCondToOutside")
      duct_subroutine.addLine("Set #{duct_lk_exhaust_fan_equiv_cond_var.name} = ImbalLkOutsideToCond")
      if not duct_location.nil?
        duct_subroutine.addLine("Set #{duct_lk_supply_fan_equiv_dz_var.name} = ImbalLkDZToOutside")
        duct_subroutine.addLine("Set #{duct_lk_exhaust_fan_equiv_dz_var.name} = ImbalLkOutsideToDZ")
      end

      # Duct Program

      duct_program = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
      duct_program.setName(object_name_idx + ' duct program')
      duct_program.addLine("Set #{ah_mfr_var.name} = #{ah_mfr_sensor.name}")
      duct_program.addLine("Set #{fan_data[:rtf_var][object].name} = 0")
      fan_data[:rtf_sensor][object].each do |rtf_sensor|
        duct_program.addLine("Set #{fan_data[:rtf_var][object].name} = #{fan_data[:rtf_var][object].name} + #{rtf_sensor.name}")
      end
      duct_program.addLine("Set #{ah_vfr_var.name} = #{ah_vfr_sensor.name}")
      duct_program.addLine("Set #{ah_tout_var.name} = #{ah_tout_sensor.name}")
      duct_program.addLine("Set #{ah_wout_var.name} = #{ah_wout_sensor.name}")
      duct_program.addLine("Set #{ra_t_var.name} = #{ra_t_sensor.name}")
      duct_program.addLine("Set #{ra_w_var.name} = #{ra_w_sensor.name}")
      duct_program.addLine("Set #{dz_t_var.name} = #{dz_t_sensor.name}")
      duct_program.addLine("Set #{dz_w_var.name} = #{dz_w}")
      duct_program.addLine("Run #{duct_subroutine.name}")
      duct_program.addLine("Set #{duct_actuators['supply_sens_lk_to_cond'].name} = #{duct_vars['supply_sens_lk_to_cond'].name}")
      duct_program.addLine("Set #{duct_actuators['supply_lat_lk_to_cond'].name} = #{duct_vars['supply_lat_lk_to_cond'].name}")
      duct_program.addLine("Set #{duct_actuators['supply_cond_to_cond'].name} = #{duct_vars['supply_cond_to_cond'].name}")
      duct_program.addLine("Set #{duct_actuators['return_sens_lk_to_rp'].name} = #{duct_vars['return_sens_lk_to_rp'].name}")
      duct_program.addLine("Set #{duct_actuators['return_lat_lk_to_rp'].name} = #{duct_vars['return_lat_lk_to_rp'].name}")
      duct_program.addLine("Set #{duct_actuators['return_cond_to_rp'].name} = #{duct_vars['return_cond_to_rp'].name}")
      duct_program.addLine("Set #{duct_actuators['return_cond_to_dz'].name} = #{duct_vars['return_cond_to_dz'].name}")
      duct_program.addLine("Set #{duct_actuators['supply_cond_to_dz'].name} = #{duct_vars['supply_cond_to_dz'].name}")
      duct_program.addLine("Set #{duct_actuators['supply_sens_lk_to_dz'].name} = #{duct_vars['supply_sens_lk_to_dz'].name}")
      duct_program.addLine("Set #{duct_actuators['supply_lat_lk_to_dz'].name} = #{duct_vars['supply_lat_lk_to_dz'].name}")
      if duct_location.is_a? OpenStudio::Model::ThermalZone
        duct_program.addLine("Set #{duct_actuators['dz_to_cond_flow_rate'].name} = #{duct_vars['dz_to_cond_flow_rate'].name}")
        duct_program.addLine("Set #{duct_actuators['cond_to_dz_flow_rate'].name} = #{duct_vars['cond_to_dz_flow_rate'].name}")
      end

      if cfis_data[:airloop].values.include? object

        cfis_id = cfis_data[:airloop].key(object)
        cfis_fan = vent_fans[:mech].find { |vfm| vfm.id == cfis_id }

        add_cfis_duct_losses = (cfis_fan.cfis_addtl_runtime_operating_mode == HPXML::CFISModeAirHandler)
        if add_cfis_duct_losses
          # Calculate additional CFIS duct losses during fan-only mode
          duct_program.addLine("If #{cfis_data[:f_damper_extra_open_var][cfis_id].name} > 0")
          duct_program.addLine("  Set cfis_m3s = (#{fan_data[:mfr_max_var][object].name} * #{cfis_fan.cfis_vent_mode_airflow_fraction} / 1.16097654)") # Density of 1.16097654 was back calculated using E+ results
          duct_program.addLine("  Set #{fan_data[:rtf_var][object].name} = #{cfis_data[:f_damper_extra_open_var][cfis_id].name}") # Need to use global vars to sync duct_program and infiltration program of different calling points
          duct_program.addLine("  Set #{ah_vfr_var.name} = #{fan_data[:rtf_var][object].name}*cfis_m3s")
          duct_program.addLine("  Set rho_in = (@RhoAirFnPbTdbW #{sensors[:pbar].name} #{sensors[:t_in].name} #{sensors[:w_in].name})")
          duct_program.addLine("  Set #{ah_mfr_var.name} = #{ah_vfr_var.name} * rho_in")
          duct_program.addLine("  Set #{ah_tout_var.name} = #{ra_t_sensor.name}")
          duct_program.addLine("  Set #{ah_wout_var.name} = #{ra_w_sensor.name}")
          duct_program.addLine("  Set #{ra_t_var.name} = #{ra_t_sensor.name}")
          duct_program.addLine("  Set #{ra_w_var.name} = #{ra_w_sensor.name}")
          duct_program.addLine("  Run #{duct_subroutine.name}")
          duct_program.addLine("  Set #{duct_actuators['cfis_supply_sens_lk_to_cond'].name} = #{duct_vars['supply_sens_lk_to_cond'].name}")
          duct_program.addLine("  Set #{duct_actuators['cfis_supply_lat_lk_to_cond'].name} = #{duct_vars['supply_lat_lk_to_cond'].name}")
          duct_program.addLine("  Set #{duct_actuators['cfis_supply_cond_to_cond'].name} = #{duct_vars['supply_cond_to_cond'].name}")
          duct_program.addLine("  Set #{duct_actuators['cfis_return_sens_lk_to_rp'].name} = #{duct_vars['return_sens_lk_to_rp'].name}")
          duct_program.addLine("  Set #{duct_actuators['cfis_return_lat_lk_to_rp'].name} = #{duct_vars['return_lat_lk_to_rp'].name}")
          duct_program.addLine("  Set #{duct_actuators['cfis_return_cond_to_rp'].name} = #{duct_vars['return_cond_to_rp'].name}")
          duct_program.addLine("  Set #{duct_actuators['cfis_return_cond_to_dz'].name} = #{duct_vars['return_cond_to_dz'].name}")
          duct_program.addLine("  Set #{duct_actuators['cfis_supply_cond_to_dz'].name} = #{duct_vars['supply_cond_to_dz'].name}")
          duct_program.addLine("  Set #{duct_actuators['cfis_supply_sens_lk_to_dz'].name} = #{duct_vars['supply_sens_lk_to_dz'].name}")
          duct_program.addLine("  Set #{duct_actuators['cfis_supply_lat_lk_to_dz'].name} = #{duct_vars['supply_lat_lk_to_dz'].name}")
          if duct_location.is_a? OpenStudio::Model::ThermalZone
            duct_program.addLine("  Set #{duct_actuators['cfis_dz_to_cond_flow_rate'].name} = #{duct_vars['dz_to_cond_flow_rate'].name}")
            duct_program.addLine("  Set #{duct_actuators['cfis_cond_to_dz_flow_rate'].name} = #{duct_vars['cond_to_dz_flow_rate'].name}")
          end
          duct_program.addLine('Else')
        end
        duct_program.addLine("  Set #{duct_actuators['cfis_supply_sens_lk_to_cond'].name} = 0")
        duct_program.addLine("  Set #{duct_actuators['cfis_supply_lat_lk_to_cond'].name} = 0")
        duct_program.addLine("  Set #{duct_actuators['cfis_supply_cond_to_cond'].name} = 0")
        duct_program.addLine("  Set #{duct_actuators['cfis_return_sens_lk_to_rp'].name} = 0")
        duct_program.addLine("  Set #{duct_actuators['cfis_return_lat_lk_to_rp'].name} = 0")
        duct_program.addLine("  Set #{duct_actuators['cfis_return_cond_to_rp'].name} = 0")
        duct_program.addLine("  Set #{duct_actuators['cfis_return_cond_to_dz'].name} = 0")
        duct_program.addLine("  Set #{duct_actuators['cfis_supply_cond_to_dz'].name} = 0")
        duct_program.addLine("  Set #{duct_actuators['cfis_supply_sens_lk_to_dz'].name} = 0")
        duct_program.addLine("  Set #{duct_actuators['cfis_supply_lat_lk_to_dz'].name} = 0")
        if duct_location.is_a? OpenStudio::Model::ThermalZone
          duct_program.addLine("  Set #{duct_actuators['cfis_dz_to_cond_flow_rate'].name} = 0")
          duct_program.addLine("  Set #{duct_actuators['cfis_cond_to_dz_flow_rate'].name} = 0")
        end
        if add_cfis_duct_losses
          duct_program.addLine('EndIf')
        end

      end

      manager = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
      manager.setName("#{duct_program.name} calling manager")
      manager.setCallingPoint('EndOfSystemTimestepAfterHVACReporting')
      manager.addProgram(duct_program)
    end

    return adiabatic_const
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param infil_values [Hash] TODO
  # @param duct_lk_imbals [TODO] TODO
  # @return [TODO] TODO
  def self.apply_infiltration_to_garage(model, spaces, hpxml_bldg, infil_values, duct_lk_imbals)
    return if spaces[HPXML::LocationGarage].nil?

    ach50 = infil_values[:ach50] * infil_values[:a_ext]

    space = spaces[HPXML::LocationGarage]
    area = UnitConversions.convert(space.floorArea, 'm^2', 'ft^2')
    volume = UnitConversions.convert(space.volume, 'm^3', 'ft^3')
    hor_lk_frac = 0.4
    neutral_level = 0.5
    sla = get_infiltration_SLA_from_ACH50(ach50, InfilPressureExponent, area, volume)
    ela = sla * area
    c_w_SG, c_s_SG = calc_wind_stack_coeffs(hpxml_bldg, hor_lk_frac, neutral_level, space)
    apply_infiltration_to_unconditioned_space(model, space, nil, ela, c_w_SG, c_s_SG, duct_lk_imbals)
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param duct_lk_imbals [TODO] TODO
  # @return [TODO] TODO
  def self.apply_infiltration_to_unconditioned_basement(model, spaces, duct_lk_imbals)
    return if spaces[HPXML::LocationBasementUnconditioned].nil?

    space = spaces[HPXML::LocationBasementUnconditioned]
    ach = get_default_unvented_space_ach()
    apply_infiltration_to_unconditioned_space(model, space, ach, nil, nil, nil, duct_lk_imbals)
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param duct_lk_imbals [TODO] TODO
  # @return [TODO] TODO
  def self.apply_infiltration_to_vented_crawlspace(model, spaces, weather, hpxml_bldg, duct_lk_imbals)
    return if spaces[HPXML::LocationCrawlspaceVented].nil?

    vented_crawl = hpxml_bldg.foundations.find { |foundation| foundation.foundation_type == HPXML::FoundationTypeCrawlspaceVented }
    space = spaces[HPXML::LocationCrawlspaceVented]
    height = Geometry.get_height_of_spaces(spaces: [space])
    sla = vented_crawl.vented_crawlspace_sla
    ach = get_infiltration_ACH_from_SLA(sla, height, weather)
    apply_infiltration_to_unconditioned_space(model, space, ach, nil, nil, nil, duct_lk_imbals)
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param duct_lk_imbals [TODO] TODO
  # @return [TODO] TODO
  def self.apply_infiltration_to_unvented_crawlspace(model, spaces, duct_lk_imbals)
    return if spaces[HPXML::LocationCrawlspaceUnvented].nil?

    space = spaces[HPXML::LocationCrawlspaceUnvented]
    ach = get_default_unvented_space_ach()
    apply_infiltration_to_unconditioned_space(model, space, ach, nil, nil, nil, duct_lk_imbals)
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param hpxml_header [HPXML::Header] HPXML Header object (one per HPXML file)
  # @param duct_lk_imbals [TODO] TODO
  # @return [TODO] TODO
  def self.apply_infiltration_to_vented_attic(model, spaces, weather, hpxml_bldg, hpxml_header, duct_lk_imbals)
    return if spaces[HPXML::LocationAtticVented].nil?

    vented_attic = hpxml_bldg.attics.find { |attic| attic.attic_type == HPXML::AtticTypeVented }
    if not vented_attic.vented_attic_sla.nil?
      if hpxml_header.apply_ashrae140_assumptions
        vented_attic_const_ach = get_infiltration_ACH_from_SLA(vented_attic.vented_attic_sla, 8.202, weather)
      else
        vented_attic_sla = vented_attic.vented_attic_sla
      end
    elsif not vented_attic.vented_attic_ach.nil?
      if hpxml_header.apply_ashrae140_assumptions
        vented_attic_const_ach = vented_attic.vented_attic_ach
      else
        vented_attic_sla = get_infiltration_SLA_from_ACH(vented_attic.vented_attic_ach, 8.202, 8.202, weather)
      end
    end

    space = spaces[HPXML::LocationAtticVented]
    if not vented_attic_sla.nil?
      vented_attic_area = UnitConversions.convert(space.floorArea, 'm^2', 'ft^2')
      hor_lk_frac = 0.75
      neutral_level = 0.5
      sla = vented_attic_sla
      ela = sla * vented_attic_area
      c_w_SG, c_s_SG = calc_wind_stack_coeffs(hpxml_bldg, hor_lk_frac, neutral_level, space)
      apply_infiltration_to_unconditioned_space(model, space, nil, ela, c_w_SG, c_s_SG, duct_lk_imbals)
    elsif not vented_attic_const_ach.nil?
      ach = vented_attic_const_ach
      apply_infiltration_to_unconditioned_space(model, space, ach, nil, nil, nil, duct_lk_imbals)
    end
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param duct_lk_imbals [TODO] TODO
  # @return [TODO] TODO
  def self.apply_infiltration_to_unvented_attic(model, spaces, duct_lk_imbals)
    return if spaces[HPXML::LocationAtticUnvented].nil?

    space = spaces[HPXML::LocationAtticUnvented]
    ach = get_default_unvented_space_ach()
    apply_infiltration_to_unconditioned_space(model, space, ach, nil, nil, nil, duct_lk_imbals)
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param vent_object [TODO] TODO
  # @param obj_type_name [TODO] TODO
  # @param index [TODO] TODO
  # @param unavailable_periods [HPXML::UnavailablePeriods] Object that defines periods for, e.g., power outages or vacancies
  # @return [TODO] TODO
  def self.apply_local_ventilation(model, spaces, vent_object, obj_type_name, index, unavailable_periods)
    daily_sch = [0.0] * 24
    obj_name = "#{obj_type_name} #{index}"
    remaining_hrs = vent_object.hours_in_operation
    for hr in 1..(vent_object.hours_in_operation.ceil)
      if remaining_hrs >= 1
        daily_sch[(vent_object.start_hour + hr - 1) % 24] = 1.0
      else
        daily_sch[(vent_object.start_hour + hr - 1) % 24] = remaining_hrs
      end
      remaining_hrs -= 1
    end
    obj_sch = HourlyByMonthSchedule.new(model, "#{obj_name} schedule", [daily_sch] * 12, [daily_sch] * 12, EPlus::ScheduleTypeLimitsFraction, false, unavailable_periods: unavailable_periods)
    obj_sch_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Schedule Value')
    obj_sch_sensor.setName("#{obj_name} sch s")
    obj_sch_sensor.setKeyName(obj_sch.schedule.name.to_s)

    equip_def = OpenStudio::Model::ElectricEquipmentDefinition.new(model)
    equip_def.setName(obj_name)
    equip = OpenStudio::Model::ElectricEquipment.new(equip_def)
    equip.setName(obj_name)
    equip.setSpace(spaces[HPXML::LocationConditionedSpace]) # no heat gain, so assign the equipment to an arbitrary space
    equip_def.setDesignLevel(vent_object.fan_power * vent_object.count)
    equip_def.setFractionRadiant(0)
    equip_def.setFractionLatent(0)
    equip_def.setFractionLost(1)
    equip.setSchedule(obj_sch.schedule)
    equip.setEndUseSubcategory(Constants::ObjectTypeMechanicalVentilation)

    return obj_sch_sensor
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param hpxml_header [HPXML::Header] HPXML Header object (one per HPXML file)
  # @param vented_dryer [TODO] TODO
  # @param schedules_file [SchedulesFile] SchedulesFile wrapper class instance of detailed schedule files
  # @param index [TODO] TODO
  # @param unavailable_periods [HPXML::UnavailablePeriods] Object that defines periods for, e.g., power outages or vacancies
  # @return [TODO] TODO
  def self.apply_dryer_exhaust(model, hpxml_header, vented_dryer, schedules_file, index, unavailable_periods)
    obj_name = "#{Constants::ObjectTypeClothesDryer} exhaust #{index}"

    # Create schedule
    obj_sch = nil
    if not schedules_file.nil?
      obj_sch_name = SchedulesFile::Columns[:ClothesDryer].name
      obj_sch = schedules_file.create_schedule_file(model, col_name: obj_sch_name)
      full_load_hrs = schedules_file.annual_equivalent_full_load_hrs(col_name: obj_sch_name)
    end
    if obj_sch.nil?
      cd_weekday_sch = vented_dryer.weekday_fractions
      cd_weekend_sch = vented_dryer.weekend_fractions
      cd_monthly_sch = vented_dryer.monthly_multipliers
      obj_sch = MonthWeekdayWeekendSchedule.new(model, obj_name + ' schedule', cd_weekday_sch, cd_weekend_sch, cd_monthly_sch, EPlus::ScheduleTypeLimitsFraction, unavailable_periods: unavailable_periods)
      obj_sch = obj_sch.schedule
      obj_sch_name = obj_sch.name.to_s
      full_load_hrs = Schedule.annual_equivalent_full_load_hrs(hpxml_header.sim_calendar_year, obj_sch)
    end

    obj_sch_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Schedule Value')
    obj_sch_sensor.setName("#{obj_name} sch s")
    obj_sch_sensor.setKeyName(obj_sch_name)

    return obj_sch_sensor, 0 if full_load_hrs == 0

    # Assume standard dryer exhaust runs 1 hr/day per BA HSP
    cfm_mult = Calendar.num_days_in_year(hpxml_header.sim_calendar_year) * vented_dryer.usage_multiplier / full_load_hrs

    return obj_sch_sensor, cfm_mult
  end

  # TODO
  #
  # @param vent_mech_fans [TODO] TODO
  # @return [TODO] TODO
  def self.calc_hrv_erv_effectiveness(vent_mech_fans)
    # Create the mapping between mech vent instance and the effectiveness results
    hrv_erv_effectiveness_map = {}
    p_atm = UnitConversions.convert(1.0, 'atm', 'psi')
    vent_mech_fans.each do |vent_mech|
      hrv_erv_effectiveness_map[vent_mech] = {}

      vent_mech_cfm = vent_mech.average_oa_unit_flow_rate
      if (vent_mech_cfm > 0)
        # Must assume an operating condition (HVI seems to use CSA 439)
        t_sup_in = 0.0
        w_sup_in = 0.0028
        t_exh_in = 22.0
        # w_exh_in = 0.0065
        cp_a = 1006.0
        p_fan = vent_mech.average_unit_fan_power # Watts

        m_fan = UnitConversions.convert(vent_mech_cfm, 'cfm', 'm^3/s') * UnitConversions.convert(Psychrometrics.rhoD_fT_w_P(UnitConversions.convert(t_sup_in, 'C', 'F'), w_sup_in, p_atm), 'lbm/ft^3', 'kg/m^3') # kg/s

        if not vent_mech.sensible_recovery_efficiency.nil?
          # The following is derived from CSA 439, Clause 9.3.3.1, Eq. 12:
          #    E_SHR = (m_sup,fan * Cp * (Tsup,out - Tsup,in) - P_sup,fan) / (m_exh,fan * Cp * (Texh,in - Tsup,in) + P_exh,fan)
          t_sup_out = t_sup_in + (vent_mech.sensible_recovery_efficiency * (m_fan * cp_a * (t_exh_in - t_sup_in) + p_fan) + p_fan) / (m_fan * cp_a)

          # Calculate the apparent sensible effectiveness
          vent_mech_apparent_sens_eff = (t_sup_out - t_sup_in) / (t_exh_in - t_sup_in)

        else
          # The following is derived from (taken from CSA 439, Clause 9.2.1, Eq. 7):
          t_sup_out = t_sup_in + (vent_mech.sensible_recovery_efficiency_adjusted * (t_exh_in - t_sup_in))

          vent_mech_apparent_sens_eff = vent_mech.sensible_recovery_efficiency_adjusted

        end

        # Calculate the supply temperature before the fan
        t_sup_out_gross = t_sup_out - p_fan / (m_fan * cp_a)

        # Sensible effectiveness of the HX only
        vent_mech_sens_eff = (t_sup_out_gross - t_sup_in) / (t_exh_in - t_sup_in)

        if (vent_mech_sens_eff < 0.0) || (vent_mech_sens_eff > 1.0)
          fail "The calculated ERV/HRV sensible effectiveness is #{vent_mech_sens_eff} but should be between 0 and 1. Please revise ERV/HRV efficiency values."
        end

        # Use summer test condition to determine the latent effectiveness since TRE is generally specified under the summer condition
        if (not vent_mech.total_recovery_efficiency.nil?) || (not vent_mech.total_recovery_efficiency_adjusted.nil?)

          t_sup_in = 35.0
          w_sup_in = 0.0178
          t_exh_in = 24.0
          w_exh_in = 0.0092

          m_fan = UnitConversions.convert(vent_mech_cfm, 'cfm', 'm^3/s') * UnitConversions.convert(Psychrometrics.rhoD_fT_w_P(UnitConversions.convert(t_sup_in, 'C', 'F'), w_sup_in, p_atm), 'lbm/ft^3', 'kg/m^3') # kg/s

          t_sup_out_gross = t_sup_in - vent_mech_sens_eff * (t_sup_in - t_exh_in)
          t_sup_out = t_sup_out_gross + p_fan / (m_fan * cp_a)

          h_sup_in = Psychrometrics.h_fT_w_SI(t_sup_in, w_sup_in)
          h_exh_in = Psychrometrics.h_fT_w_SI(t_exh_in, w_exh_in)

          if not vent_mech.total_recovery_efficiency.nil?
            # The following is derived from CSA 439, Clause 9.3.3.2, Eq. 13:
            #    E_THR = (m_sup,fan * Cp * (h_sup,out - h_sup,in) - P_sup,fan) / (m_exh,fan * Cp * (h_exh,in - h_sup,in) + P_exh,fan)
            h_sup_out = h_sup_in - (vent_mech.total_recovery_efficiency * (m_fan * (h_sup_in - h_exh_in) + p_fan) + p_fan) / m_fan
          else
            # The following is derived from (taken from CSA 439, Clause 9.2.1, Eq. 7):
            h_sup_out = h_sup_in - (vent_mech.total_recovery_efficiency_adjusted * (h_sup_in - h_exh_in))
          end

          w_sup_out = Psychrometrics.w_fT_h_SI(t_sup_out, h_sup_out)
          vent_mech_lat_eff = [0.0, (w_sup_out - w_sup_in) / (w_exh_in - w_sup_in)].max

          if (vent_mech_lat_eff < 0.0) || (vent_mech_lat_eff > 1.0)
            fail "The calculated ERV/HRV latent effectiveness is #{vent_mech_lat_eff} but should be between 0 and 1. Please revise ERV/HRV efficiency values."
          end

        else
          vent_mech_lat_eff = 0.0
        end
      else
        vent_mech_apparent_sens_eff = 0.0
        vent_mech_sens_eff = 0.0
        vent_mech_lat_eff = 0.0
      end

      hrv_erv_effectiveness_map[vent_mech][:vent_mech_sens_eff] = vent_mech_sens_eff
      hrv_erv_effectiveness_map[vent_mech][:vent_mech_lat_eff] = vent_mech_lat_eff
      hrv_erv_effectiveness_map[vent_mech][:vent_mech_apparent_sens_eff] = vent_mech_apparent_sens_eff
    end
    return hrv_erv_effectiveness_map
  end

  # TODO
  #
  # @param runner [OpenStudio::Measure::OSRunner] Object typically used to display warnings
  # @param infil_program [TODO] TODO
  # @param vent_mech_fans [TODO] TODO
  # @param cfis_data [TODO] TODO
  # @param cfis_fan_actuator [TODO] TODO
  # @param cfis_suppl_fan_actuator [TODO] TODO
  # @param fan_data [TODO] TODO
  # @return [nil]
  def self.apply_cfis(runner, infil_program, vent_mech_fans, cfis_data, cfis_fan_actuator, cfis_suppl_fan_actuator, fan_data)
    infil_program.addLine('Set QWHV_cfis_sup = 0.0') # CFIS supply outdoor airflow rate
    infil_program.addLine('Set QWHV_cfis_suppl_sup = 0.0') # CFIS supplemental fan supply outdoor airflow rate
    infil_program.addLine('Set QWHV_cfis_suppl_exh = 0.0') # CFIS supplemental fan exhaust outdoor airflow rate

    vent_mech_fans.each do |vent_mech|
      infil_program.addLine('Set fan_rtf_hvac = 0')
      object = cfis_data[:airloop][vent_mech.id]
      fan_data[:rtf_sensor][object].each do |rtf_sensor|
        infil_program.addLine("Set fan_rtf_hvac = fan_rtf_hvac + #{rtf_sensor.name}")
      end
      infil_program.addLine("Set cfis_fan_w = #{vent_mech.unit_fan_power}") # W

      infil_program.addLine('If @ABS(Minute - ZoneTimeStep*60) < 0.1')
      infil_program.addLine("  Set #{cfis_data[:t_sum_open_var][vent_mech.id].name} = 0") # New hour, time on summation re-initializes to 0
      infil_program.addLine('EndIf')

      infil_program.addLine("Set cfis_t_min_hr_open = #{[vent_mech.hours_in_operation / 24.0 * 60.0, 59.999].min}") # # Minimum CFIS damper open time in minutes
      infil_program.addLine("Set cfis_Q_duct_oa = #{UnitConversions.convert(vent_mech.oa_unit_flow_rate, 'cfm', 'm^3/s')}")
      infil_program.addLine('Set cfis_f_damper_open = 0') # fraction of the timestep the CFIS damper is open
      infil_program.addLine("Set #{cfis_data[:f_damper_extra_open_var][vent_mech.id].name} = 0") # additional runtime fraction to meet min/hr
      infil_program.addLine("Set cfis_has_additional_runtime = #{vent_mech.cfis_addtl_runtime_operating_mode == HPXML::CFISModeNone ? 0 : 1}")

      infil_program.addLine("If #{cfis_data[:t_sum_open_var][vent_mech.id].name} < cfis_t_min_hr_open")
      infil_program.addLine("  Set cfis_t_fan_on = 60 - (cfis_t_min_hr_open - #{cfis_data[:t_sum_open_var][vent_mech.id].name})") # Minute of the hour at which the blower needs to turn on to meet the ventilation requirements
      infil_program.addLine('  If ((Minute+0.00001) >= cfis_t_fan_on) && (cfis_has_additional_runtime == 1)') # Evaluate condition of whether supply fan has to run to achieve target minutes per hour of operation
      infil_program.addLine('    Set cfis_fan_runtime = @Max (@ABS(Minute - cfis_t_fan_on)) (fan_rtf_hvac * ZoneTimeStep * 60)') # Consider fan rtf read in current calling point (results of previous time step) + cfis_t_fan_on based on min/hr requirement and previous EMS results.
      infil_program.addLine("    Set cfis_fan_runtime = @Min cfis_fan_runtime (cfis_t_min_hr_open - #{cfis_data[:t_sum_open_var][vent_mech.id].name})") # If fan_rtf_hvac, make sure it's not exceeding ventilation requirements
      infil_program.addLine('    Set cfis_f_damper_open = cfis_fan_runtime / (60.0 * ZoneTimeStep)') # calculates the portion of the current timestep the CFIS damper needs to be open
      infil_program.addLine("    Set #{cfis_data[:t_sum_open_var][vent_mech.id].name} = #{cfis_data[:t_sum_open_var][vent_mech.id].name} + cfis_fan_runtime")
      infil_program.addLine("    Set #{cfis_data[:f_damper_extra_open_var][vent_mech.id].name} = @Max (cfis_f_damper_open - fan_rtf_hvac) 0.0")
      if vent_mech.cfis_addtl_runtime_operating_mode == HPXML::CFISModeAirHandler
        # Air handler meets additional runtime requirement
        infil_program.addLine("    Set #{cfis_fan_actuator.name} = #{cfis_fan_actuator.name} + cfis_fan_w * #{cfis_data[:f_damper_extra_open_var][vent_mech.id].name}")
      elsif vent_mech.cfis_addtl_runtime_operating_mode == HPXML::CFISModeSupplementalFan
        if vent_mech.cfis_supplemental_fan.oa_unit_flow_rate < vent_mech.average_unit_flow_rate
          runner.registerWarning("CFIS supplemental fan '#{vent_mech.cfis_supplemental_fan.id}' is undersized (#{vent_mech.cfis_supplemental_fan.oa_unit_flow_rate} cfm) compared to the target hourly ventilation rate (#{vent_mech.average_unit_flow_rate} cfm).")
        end
        infil_program.addLine("    Set cfis_suppl_Q_oa = #{UnitConversions.convert(vent_mech.cfis_supplemental_fan.oa_unit_flow_rate, 'cfm', 'm^3/s')}")
        if vent_mech.cfis_supplemental_fan.oa_unit_flow_rate > 0
          infil_program.addLine("    Set cfis_suppl_f = #{cfis_data[:f_damper_extra_open_var][vent_mech.id].name} / (cfis_suppl_Q_oa / cfis_Q_duct_oa)") # Calculate desired runtime for supplemental fan to provide remaining ventilation requirement
          infil_program.addLine('    Set cfis_suppl_f = @Min cfis_suppl_f 1.0') # Ensure desired runtime does not exceed 100% (if the supplemental fan is undersized)
        else
          infil_program.addLine('    Set cfis_suppl_f = 0.0')
        end
        infil_program.addLine("    Set cfis_suppl_fan_w = #{vent_mech.cfis_supplemental_fan.unit_fan_power}") # W
        infil_program.addLine("    Set #{cfis_suppl_fan_actuator.name} = #{cfis_suppl_fan_actuator.name} + cfis_suppl_fan_w * cfis_suppl_f")
        if vent_mech.cfis_supplemental_fan.fan_type == HPXML::MechVentTypeSupply
          infil_program.addLine('    Set QWHV_cfis_suppl_sup = QWHV_cfis_suppl_sup + cfis_suppl_f * cfis_suppl_Q_oa')
        elsif vent_mech.cfis_supplemental_fan.fan_type == HPXML::MechVentTypeExhaust
          infil_program.addLine('    Set QWHV_cfis_suppl_exh = QWHV_cfis_suppl_exh + cfis_suppl_f * cfis_suppl_Q_oa')
        end
      end
      infil_program.addLine('  Else') # No need to turn on blower for extra ventilation
      infil_program.addLine('    Set cfis_fan_runtime = fan_rtf_hvac * ZoneTimeStep * 60')
      infil_program.addLine("    If (#{cfis_data[:t_sum_open_var][vent_mech.id].name} + cfis_fan_runtime) > cfis_t_min_hr_open") # Damper is only open for a portion of this time step to achieve target minutes per hour
      infil_program.addLine("      Set cfis_fan_runtime = cfis_t_min_hr_open - #{cfis_data[:t_sum_open_var][vent_mech.id].name}")
      infil_program.addLine('      Set cfis_f_damper_open = cfis_fan_runtime / (ZoneTimeStep * 60)')
      infil_program.addLine("      Set #{cfis_data[:t_sum_open_var][vent_mech.id].name} = cfis_t_min_hr_open")
      infil_program.addLine('    Else') # Damper is open and using call for heat/cool to supply fresh air
      infil_program.addLine('      Set cfis_fan_runtime = fan_rtf_hvac * ZoneTimeStep * 60')
      infil_program.addLine('      Set cfis_f_damper_open = fan_rtf_hvac')
      infil_program.addLine("      Set #{cfis_data[:t_sum_open_var][vent_mech.id].name} = #{cfis_data[:t_sum_open_var][vent_mech.id].name} + cfis_fan_runtime")
      infil_program.addLine('    EndIf')
      infil_program.addLine('  EndIf')

      if vent_mech.cfis_addtl_runtime_operating_mode == HPXML::CFISModeSupplementalFan
        infil_program.addLine("  Set cfis_f_damper_open = @Max (cfis_f_damper_open - #{cfis_data[:f_damper_extra_open_var][vent_mech.id].name}) 0.0")
      end
      infil_program.addLine('  Set QWHV_cfis_sup = QWHV_cfis_sup + cfis_f_damper_open * cfis_Q_duct_oa')

      infil_program.addLine('EndIf')
    end
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param obj_name [String] Name for the OpenStudio object
  # @param sup_fans [TODO] TODO
  # @param exh_fans [TODO] TODO
  # @param bal_fans [TODO] TODO
  # @param erv_hrv_fans [TODO] TODO
  # @param unavailable_periods [HPXML::UnavailablePeriods] Object that defines periods for, e.g., power outages or vacancies
  # @return [TODO] TODO
  def self.add_ee_for_vent_fan_power(model, spaces, obj_name, sup_fans = [], exh_fans = [], bal_fans = [], erv_hrv_fans = [], unavailable_periods = [])
    # Calculate fan heat fraction
    # 1.0: Fan heat does not enter space (e.g., exhaust)
    # 0.0: Fan heat does enter space (e.g., supply)
    if obj_name == Constants::ObjectTypeMechanicalVentilationHouseFanCFIS
      fan_heat_lost_fraction = 0.0
    else
      # Calculate total fan power
      if obj_name == Constants::ObjectTypeMechanicalVentilationHouseFanCFISSupplFan
        sup_fans_w = sup_fans.map { |f| f.unit_fan_power }.sum(0.0)
        exh_fans_w = exh_fans.map { |f| f.unit_fan_power }.sum(0.0)
        bal_fans_w = (bal_fans + erv_hrv_fans).map { |f| f.unit_fan_power }.sum(0.0)
      else
        sup_fans_w = sup_fans.map { |f| f.average_unit_fan_power }.sum(0.0)
        exh_fans_w = exh_fans.map { |f| f.average_unit_fan_power }.sum(0.0)
        bal_fans_w = (bal_fans + erv_hrv_fans).map { |f| f.average_unit_fan_power }.sum(0.0)
      end
      tot_fans_w = sup_fans_w + exh_fans_w + bal_fans_w

      # Calculate weighted-average value
      if tot_fans_w > 0.0
        fan_heat_lost_fraction = (1.0 * exh_fans_w + 0.0 * sup_fans_w + 0.5 * bal_fans_w) / tot_fans_w
      else
        fan_heat_lost_fraction = 1.0
      end
    end

    # Availability Schedule
    avail_sch = ScheduleConstant.new(model, obj_name + ' schedule', 1.0, EPlus::ScheduleTypeLimitsFraction, unavailable_periods: unavailable_periods)
    avail_sch = avail_sch.schedule

    equip_def = OpenStudio::Model::ElectricEquipmentDefinition.new(model)
    equip_def.setName(obj_name)
    equip = OpenStudio::Model::ElectricEquipment.new(equip_def)
    equip.setName(obj_name)
    equip.setSpace(spaces[HPXML::LocationConditionedSpace])
    equip_def.setFractionRadiant(0)
    equip_def.setFractionLatent(0)
    equip.setSchedule(avail_sch)
    equip.setEndUseSubcategory(Constants::ObjectTypeMechanicalVentilation)
    equip_def.setFractionLost(fan_heat_lost_fraction)
    equip_actuator = nil
    if [Constants::ObjectTypeMechanicalVentilationHouseFanCFIS,
        Constants::ObjectTypeMechanicalVentilationHouseFanCFISSupplFan].include? obj_name # actuate its power level in EMS
      equip_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(equip, *EPlus::EMSActuatorElectricEquipmentPower, equip.space.get)
      equip_actuator.setName("#{equip.name} act")
    end
    if not tot_fans_w.nil?
      equip_def.setDesignLevel(tot_fans_w)
    end

    return equip_actuator
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param program [TODO] TODO
  # @param sensors [Hash] Map of :sensor_types => EMS sensors
  # @return [TODO] TODO
  def self.setup_mech_vent_vars_actuators(model, spaces, program, sensors)
    conditioned_space = spaces[HPXML::LocationConditionedSpace]

    # Actuators for mech vent fan
    sens_name = "#{Constants::ObjectTypeMechanicalVentilationHouseFan} sensible load"
    fan_sens_load_actuator = create_other_equipment_object_and_actuator(model: model, name: sens_name, space: conditioned_space, frac_lat: 0.0, frac_lost: 0.0, end_use: Constants::ObjectTypeMechanicalVentilationHouseFan)

    lat_name = "#{Constants::ObjectTypeMechanicalVentilationHouseFan} latent load"
    fan_lat_load_actuator = create_other_equipment_object_and_actuator(model: model, name: lat_name, space: conditioned_space, frac_lat: 1.0, frac_lost: 0.0, end_use: Constants::ObjectTypeMechanicalVentilationHouseFan)

    program.addLine("Set #{fan_sens_load_actuator.name} = 0.0")
    program.addLine("Set #{fan_lat_load_actuator.name} = 0.0")

    # Air property at inlet nodes on both sides
    program.addLine("Set OASupInPb = #{sensors[:pbar].name}") # oa barometric pressure
    program.addLine("Set OASupInTemp = #{sensors[:t_out].name}") # oa db temperature
    program.addLine("Set OASupInW = #{sensors[:w_out].name}") # oa humidity ratio
    program.addLine('Set OASupRho = (@RhoAirFnPbTdbW OASupInPb OASupInTemp OASupInW)')
    program.addLine('Set OASupCp = (@CpAirFnW OASupInW)')
    program.addLine('Set OASupInEnth = (@HFnTdbW OASupInTemp OASupInW)')

    program.addLine("Set ZoneTemp = #{sensors[:t_in].name}") # zone air temperature
    program.addLine("Set ZoneW = #{sensors[:w_in].name}") # zone air humidity ratio
    program.addLine('Set ZoneCp = (@CpAirFnW ZoneW)')
    program.addLine('Set ZoneAirEnth = (@HFnTdbW ZoneTemp ZoneW)')

    return fan_sens_load_actuator, fan_lat_load_actuator
  end

  # TODO
  #
  # @param runner [OpenStudio::Measure::OSRunner] Object typically used to display warnings
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param hpxml_header [HPXML::Header] HPXML Header object (one per HPXML file)
  # @param infil_program [TODO] TODO
  # @param vent_fans [TODO] TODO
  # @param duct_lk_imbals [TODO] TODO
  # @param infil_flow_actuator [TODO] TODO
  # @param schedules_file [SchedulesFile] SchedulesFile wrapper class instance of detailed schedule files
  # @return [nil]
  def self.apply_infiltration_adjustment_to_conditioned(runner, model, spaces, hpxml_bldg, hpxml_header, infil_program, vent_fans, duct_lk_imbals, infil_flow_actuator, schedules_file)
    conditioned_space = spaces[HPXML::LocationConditionedSpace]
    conditioned_zone = conditioned_space.thermalZone.get

    # Average in-unit CFMs (include recirculation from in unit CFMs for shared systems)
    sup_cfm_tot = vent_fans[:mech_supply].map { |vent_mech| vent_mech.average_unit_flow_rate }.sum(0.0)
    exh_cfm_tot = vent_fans[:mech_exhaust].map { |vent_mech| vent_mech.average_unit_flow_rate }.sum(0.0)
    bal_cfm_tot = vent_fans[:mech_balanced].map { |vent_mech| vent_mech.average_unit_flow_rate }.sum(0.0)
    erv_hrv_cfm_tot = vent_fans[:mech_erv_hrv].map { |vent_mech| vent_mech.average_unit_flow_rate }.sum(0.0)

    infil_program.addLine('Set Qrange = 0')
    cooking_range_in_cond_space = hpxml_bldg.cooking_ranges.empty? ? true : HPXML::conditioned_locations_this_unit.include?(hpxml_bldg.cooking_ranges[0].location)
    vent_fans[:kitchen].each_with_index do |vent_kitchen, index|
      # Electricity impact
      vent_kitchen_unavailable_periods = Schedule.get_unavailable_periods(runner, SchedulesFile::Columns[:KitchenFan].name, hpxml_header.unavailable_periods)
      obj_sch_sensor = apply_local_ventilation(model, spaces, vent_kitchen, Constants::ObjectTypeMechanicalVentilationRangeFan, index, vent_kitchen_unavailable_periods)
      next unless cooking_range_in_cond_space

      # Infiltration impact
      infil_program.addLine("Set Qrange = Qrange + #{UnitConversions.convert(vent_kitchen.flow_rate * vent_kitchen.count, 'cfm', 'm^3/s').round(5)} * #{obj_sch_sensor.name}")
    end

    infil_program.addLine('Set Qbath = 0')
    vent_fans[:bath].each_with_index do |vent_bath, index|
      # Electricity impact
      vent_bath_unavailable_periods = Schedule.get_unavailable_periods(runner, SchedulesFile::Columns[:BathFan].name, hpxml_header.unavailable_periods)
      obj_sch_sensor = apply_local_ventilation(model, spaces, vent_bath, Constants::ObjectTypeMechanicalVentilationBathFan, index, vent_bath_unavailable_periods)
      # Infiltration impact
      infil_program.addLine("Set Qbath = Qbath + #{UnitConversions.convert(vent_bath.flow_rate * vent_bath.count, 'cfm', 'm^3/s').round(5)} * #{obj_sch_sensor.name}")
    end

    infil_program.addLine('Set Qdryer = 0')
    clothes_dryer_in_cond_space = hpxml_bldg.clothes_dryers.empty? ? true : HPXML::conditioned_locations_this_unit.include?(hpxml_bldg.clothes_dryers[0].location)
    vented_dryers = hpxml_bldg.clothes_dryers.select { |cd| cd.is_vented && cd.vented_flow_rate.to_f > 0 }
    vented_dryers.each_with_index do |vented_dryer, index|
      next unless clothes_dryer_in_cond_space

      # Infiltration impact
      vented_dryer_unavailable_periods = Schedule.get_unavailable_periods(runner, SchedulesFile::Columns[:ClothesDryer].name, hpxml_header.unavailable_periods)
      obj_sch_sensor, cfm_mult = apply_dryer_exhaust(model, hpxml_header, vented_dryer, schedules_file, index, vented_dryer_unavailable_periods)
      infil_program.addLine("Set Qdryer = Qdryer + #{UnitConversions.convert(vented_dryer.vented_flow_rate * cfm_mult, 'cfm', 'm^3/s').round(5)} * #{obj_sch_sensor.name}")
    end

    infil_program.addLine("Set QWHV_sup = #{UnitConversions.convert(sup_cfm_tot + bal_cfm_tot + erv_hrv_cfm_tot, 'cfm', 'm^3/s').round(5)}")
    infil_program.addLine("Set QWHV_exh = #{UnitConversions.convert(exh_cfm_tot + bal_cfm_tot + erv_hrv_cfm_tot, 'cfm', 'm^3/s').round(5)}")

    # Ventilation fans
    infil_program.addLine('Set Qsupply = QWHV_sup + QWHV_cfis_sup + QWHV_cfis_suppl_sup')
    infil_program.addLine('Set Qexhaust = Qrange + Qbath + Qdryer + QWHV_exh + QWHV_cfis_suppl_exh')
    infil_program.addLine('Set Qfan = (@Max Qexhaust Qsupply)')

    # Duct leakage imbalance induced infiltration
    infil_program.addLine('Set Qducts = 0')
    duct_lk_imbals.each do |values|
      duct_location, duct_lk_supply_fan_equiv_var, duct_lk_exhaust_fan_equiv_var = values
      next if duct_location != conditioned_zone.name.to_s

      infil_program.addLine("Set Qducts = Qducts - #{duct_lk_supply_fan_equiv_var.name}")
      infil_program.addLine("Set Qducts = Qducts + #{duct_lk_exhaust_fan_equiv_var.name}")
    end
    infil_program.addLine('If Qducts < 0')
    infil_program.addLine('  Set Qsupply = Qsupply - Qducts')
    infil_program.addLine('Else')
    infil_program.addLine('  Set Qexhaust = Qexhaust + Qducts')
    infil_program.addLine('EndIf')
    infil_program.addLine('Set Qfan_with_ducts = (@Max Qexhaust Qsupply)')

    # Total combined air exchange
    if Constants::ERIVersions.index(hpxml_header.eri_calculation_version) >= Constants::ERIVersions.index('2022')
      infil_program.addLine('Set Qimb = (@Abs (Qsupply - Qexhaust))')
      infil_program.addLine('If Qinf + Qimb > 0')
      infil_program.addLine('  Set Qtot = Qfan_with_ducts + (Qinf^2) / (Qinf + Qimb)')
      infil_program.addLine('Else')
      infil_program.addLine('  Set Qtot = Qfan_with_ducts')
      infil_program.addLine('EndIf')
    elsif Constants::ERIVersions.index(hpxml_header.eri_calculation_version) >= Constants::ERIVersions.index('2019')
      # Follow ASHRAE 62.2-2016, Normative Appendix C equations for time-varying total airflow
      infil_program.addLine('If Qfan_with_ducts > 0')
      # Balanced system if the total supply airflow and total exhaust airflow are within 10% of their average.
      infil_program.addLine('  Set Qavg = ((Qexhaust + Qsupply) / 2.0)')
      infil_program.addLine('  If ((@Abs (Qexhaust - Qavg)) / Qavg) <= 0.1') # Only need to check Qexhaust, Qsupply will give same result
      infil_program.addLine('    Set phi = 1')
      infil_program.addLine('  Else')
      infil_program.addLine('    Set phi = (Qinf / (Qinf + Qfan_with_ducts))')
      infil_program.addLine('  EndIf')
      infil_program.addLine('  Set Qtot = Qfan_with_ducts + (phi * Qinf)')
      infil_program.addLine('Else')
      infil_program.addLine('  Set Qtot = Qfan_with_ducts + Qinf')
      infil_program.addLine('EndIf')
    else
      infil_program.addLine('Set Qimb = (@Abs (Qexhaust - Qsupply))') # Unbalanced flow
      infil_program.addLine('Set Qbal = Qfan_with_ducts - Qimb') # Balanced flow
      infil_program.addLine('Set Qtot = (((Qimb^2) + (Qinf^2)) ^ 0.5) + Qbal')
    end

    # Natural infiltration and duct leakage imbalance induced infiltration
    infil_program.addLine('Set Qinf_adj = Qtot - Qfan')
    infil_program.addLine("Set #{infil_flow_actuator.name} = Qinf_adj")

    # EMS global variables for output reporting
    q_inf_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{infil_program.name}_Qinf")
    q_fan_var = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "#{infil_program.name}_Qfan")
    q_inf_var.additionalProperties.setFeature('ObjectType', Constants::ObjectTypeInfiltration)
    q_fan_var.additionalProperties.setFeature('ObjectType', Constants::ObjectTypeMechanicalVentilation)
    infil_program.addLine("Set #{q_inf_var.name} = Qinf_adj")
    infil_program.addLine("Set #{q_fan_var.name} = Qfan")
  end

  # TODO
  #
  # @param infil_program [TODO] TODO
  # @param vent_mech_erv_hrv_tot [TODO] TODO
  # @param hrv_erv_effectiveness_map [TODO] TODO
  # @param fan_sens_load_actuator [TODO] TODO
  # @param fan_lat_load_actuator [TODO] TODO
  # @param q_var [TODO] TODO
  # @param preconditioned [TODO] TODO
  # @return [nil]
  def self.calculate_fan_loads(infil_program, vent_mech_erv_hrv_tot, hrv_erv_effectiveness_map, fan_sens_load_actuator, fan_lat_load_actuator, q_var, preconditioned = false)
    # Variables for combined effectiveness
    infil_program.addLine('Set Effectiveness_Sens = 0.0')
    infil_program.addLine('Set Effectiveness_Lat = 0.0')

    # Calculate mass flow rate based on outdoor air density
    # Address load with flow-weighted combined effectiveness
    infil_program.addLine("Set Fan_MFR = #{q_var} * OASupRho")
    infil_program.addLine('Set ZoneInEnth = OASupInEnth')
    infil_program.addLine('Set ZoneInTemp = OASupInTemp')
    if not vent_mech_erv_hrv_tot.empty?
      # ERV/HRV EMS load model
      # E+ ERV model is using standard density for MFR calculation, caused discrepancy with other system types.
      # Therefore ERV is modeled within EMS infiltration program
      infil_program.addLine("If #{q_var} > 0")
      vent_mech_erv_hrv_tot.each do |vent_fan|
        sens_eff = hrv_erv_effectiveness_map[vent_fan][:vent_mech_sens_eff]
        lat_eff = hrv_erv_effectiveness_map[vent_fan][:vent_mech_lat_eff]
        avg_oa_m3s = UnitConversions.convert(vent_fan.average_oa_unit_flow_rate, 'cfm', 'm^3/s').round(4)
        infil_program.addLine("  Set Effectiveness_Sens = Effectiveness_Sens + #{avg_oa_m3s} / #{q_var} * #{sens_eff}")
        infil_program.addLine("  Set Effectiveness_Lat = Effectiveness_Lat + #{avg_oa_m3s} / #{q_var} * #{lat_eff}")
      end
      infil_program.addLine('EndIf')
      infil_program.addLine('Set ERVCpMin = (@Min OASupCp ZoneCp)')
      infil_program.addLine('Set ERVSupOutTemp = OASupInTemp + ERVCpMin/OASupCp * Effectiveness_Sens * (ZoneTemp - OASupInTemp)')
      infil_program.addLine('Set ERVSupOutW = OASupInW + ERVCpMin/OASupCp * Effectiveness_Lat * (ZoneW - OASupInW)')
      infil_program.addLine('Set ERVSupOutEnth = (@HFnTdbW ERVSupOutTemp ERVSupOutW)')
      infil_program.addLine('Set ERVSensHeatTrans = Fan_MFR * OASupCp * (ERVSupOutTemp - OASupInTemp)')
      infil_program.addLine('Set ERVTotalHeatTrans = Fan_MFR * (ERVSupOutEnth - OASupInEnth)')
      infil_program.addLine('Set ERVLatHeatTrans = ERVTotalHeatTrans - ERVSensHeatTrans')
      # ERV/HRV Load calculation
      infil_program.addLine('Set ZoneInEnth = ERVSupOutEnth')
      infil_program.addLine('Set ZoneInTemp = ERVSupOutTemp')
    end
    infil_program.addLine('Set FanTotalToCond = Fan_MFR * (ZoneInEnth - ZoneAirEnth)')
    infil_program.addLine('Set FanSensToCond = Fan_MFR * ZoneCp * (ZoneInTemp - ZoneTemp)')
    infil_program.addLine('Set FanLatToCond = FanTotalToCond - FanSensToCond')

    # Actuator,
    # If preconditioned, handle actuators later in calculate_precond_loads
    if not preconditioned
      infil_program.addLine("Set #{fan_sens_load_actuator.name} = #{fan_sens_load_actuator.name} + FanSensToCond")
      infil_program.addLine("Set #{fan_lat_load_actuator.name} = #{fan_lat_load_actuator.name} + FanLatToCond")
    end
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param infil_program [TODO] TODO
  # @param vent_fans [TODO] TODO
  # @param hrv_erv_effectiveness_map [TODO] TODO
  # @param fan_sens_load_actuator [TODO] TODO
  # @param fan_lat_load_actuator [TODO] TODO
  # @param clg_ssn_sensor [TODO] TODO
  # @return [nil]
  def self.calculate_precond_loads(model, spaces, infil_program, vent_fans, hrv_erv_effectiveness_map, fan_sens_load_actuator, fan_lat_load_actuator, clg_ssn_sensor)
    conditioned_space = spaces[HPXML::LocationConditionedSpace]
    conditioned_zone = conditioned_space.thermalZone.get

    # Preconditioning
    # Assume introducing no sensible loads to zone if preconditioned
    if not vent_fans[:mech_preheat].empty?
      htg_stp_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Zone Thermostat Heating Setpoint Temperature')
      htg_stp_sensor.setName('htg stp s')
      htg_stp_sensor.setKeyName(conditioned_zone.name.to_s)
      infil_program.addLine("Set HtgStp = #{htg_stp_sensor.name}") # heating thermostat setpoint
    end
    if not vent_fans[:mech_precool].empty?
      clg_stp_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Zone Thermostat Cooling Setpoint Temperature')
      clg_stp_sensor.setName('clg stp s')
      clg_stp_sensor.setKeyName(conditioned_zone.name.to_s)
      infil_program.addLine("Set ClgStp = #{clg_stp_sensor.name}") # cooling thermostat setpoint
    end
    vent_fans[:mech_preheat].each_with_index do |f_preheat, i|
      infil_program.addLine("If (OASupInTemp < HtgStp) && (#{clg_ssn_sensor.name} < 1)")
      cnt = model.getOtherEquipments.select { |e| e.endUseSubcategory.start_with? Constants::ObjectTypeMechanicalVentilationPreheating }.size # Ensure unique meter for each preheating system
      htg_energy_actuator = create_other_equipment_object_and_actuator(model: model, name: "shared mech vent preheating energy #{i}", space: conditioned_space, frac_lat: 0.0, frac_lost: 1.0, hpxml_fuel_type: f_preheat.preheating_fuel, end_use: "#{Constants::ObjectTypeMechanicalVentilationPreheating}#{cnt + 1}")
      htg_energy_actuator.actuatedComponent.get.additionalProperties.setFeature('HPXML_ID', f_preheat.id) # Used by reporting measure
      infil_program.addLine("  Set Qpreheat = #{UnitConversions.convert(f_preheat.average_oa_unit_flow_rate, 'cfm', 'm^3/s').round(4)}")
      if [HPXML::MechVentTypeERV, HPXML::MechVentTypeHRV].include? f_preheat.fan_type
        vent_mech_erv_hrv_tot = [f_preheat]
      else
        vent_mech_erv_hrv_tot = []
      end
      calculate_fan_loads(infil_program, vent_mech_erv_hrv_tot, hrv_erv_effectiveness_map, fan_sens_load_actuator, fan_lat_load_actuator, 'Qpreheat', true)

      infil_program.addLine('  If ZoneInTemp < HtgStp')
      infil_program.addLine('    Set FanSensToSpt = Fan_MFR * ZoneCp * (ZoneInTemp - HtgStp)')
      infil_program.addLine("    Set PreHeatingWatt = (-FanSensToSpt) * #{f_preheat.preheating_fraction_load_served}")
      infil_program.addLine("    Set #{fan_sens_load_actuator.name} = #{fan_sens_load_actuator.name} + PreHeatingWatt")
      infil_program.addLine("    Set #{fan_lat_load_actuator.name} = #{fan_lat_load_actuator.name} - FanLatToCond")
      infil_program.addLine('  Else')
      infil_program.addLine('    Set PreHeatingWatt = 0.0')
      infil_program.addLine('  EndIf')
      infil_program.addLine('Else')
      infil_program.addLine('  Set PreHeatingWatt = 0.0')
      infil_program.addLine('EndIf')
      infil_program.addLine("Set #{htg_energy_actuator.name} = PreHeatingWatt / #{f_preheat.preheating_efficiency_cop}")
    end
    vent_fans[:mech_precool].each_with_index do |f_precool, i|
      infil_program.addLine("If (OASupInTemp > ClgStp) && (#{clg_ssn_sensor.name} > 0)")
      cnt = model.getOtherEquipments.select { |e| e.endUseSubcategory.start_with? Constants::ObjectTypeMechanicalVentilationPrecooling }.size # Ensure unique meter for each precooling system
      clg_energy_actuator = create_other_equipment_object_and_actuator(model: model, name: "shared mech vent precooling energy #{i}", space: conditioned_space, frac_lat: 0.0, frac_lost: 1.0, hpxml_fuel_type: f_precool.precooling_fuel, end_use: "#{Constants::ObjectTypeMechanicalVentilationPrecooling}#{cnt + 1}")
      clg_energy_actuator.actuatedComponent.get.additionalProperties.setFeature('HPXML_ID', f_precool.id) # Used by reporting measure
      infil_program.addLine("  Set Qprecool = #{UnitConversions.convert(f_precool.average_oa_unit_flow_rate, 'cfm', 'm^3/s').round(4)}")
      if [HPXML::MechVentTypeERV, HPXML::MechVentTypeHRV].include? f_precool.fan_type
        vent_mech_erv_hrv_tot = [f_precool]
      else
        vent_mech_erv_hrv_tot = []
      end
      calculate_fan_loads(infil_program, vent_mech_erv_hrv_tot, hrv_erv_effectiveness_map, fan_sens_load_actuator, fan_lat_load_actuator, 'Qprecool', true)

      infil_program.addLine('  If ZoneInTemp > ClgStp')
      infil_program.addLine('    Set FanSensToSpt = Fan_MFR * ZoneCp * (ZoneInTemp - ClgStp)')
      infil_program.addLine("    Set PreCoolingWatt = FanSensToSpt * #{f_precool.precooling_fraction_load_served}")
      infil_program.addLine("    Set #{fan_sens_load_actuator.name} = #{fan_sens_load_actuator.name}  - PreCoolingWatt")
      infil_program.addLine("    Set #{fan_lat_load_actuator.name} = #{fan_lat_load_actuator.name} - FanLatToCond") # Fixme:Does this assumption still apply?
      infil_program.addLine('  Else')
      infil_program.addLine('    Set PreCoolingWatt = 0.0')
      infil_program.addLine('  EndIf')
      infil_program.addLine('Else')
      infil_program.addLine('  Set PreCoolingWatt = 0.0')
      infil_program.addLine('EndIf')
      infil_program.addLine("Set #{clg_energy_actuator.name} = PreCoolingWatt / #{f_precool.precooling_efficiency_cop}")
    end
  end

  # TODO
  #
  # @param runner [OpenStudio::Measure::OSRunner] Object typically used to display warnings
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param hpxml_header [HPXML::Header] HPXML Header object (one per HPXML file)
  # @param vent_fans [TODO] TODO
  # @param infil_values [Hash] TODO
  # @param clg_ssn_sensor [TODO] TODO
  # @param schedules_file [SchedulesFile] SchedulesFile wrapper class instance of detailed schedule files
  # @param duct_lk_imbals [TODO] TODO
  # @param cfis_data [TODO] TODO
  # @param fan_data [TODO] TODO
  # @param sensors [Hash] Map of :sensor_types => EMS sensors
  # @return [nil]
  def self.apply_infiltration_ventilation_to_conditioned(runner, model, spaces, weather, hpxml_bldg, hpxml_header, vent_fans, infil_values,
                                                         clg_ssn_sensor, schedules_file, duct_lk_imbals, cfis_data, fan_data, sensors)
    # Categorize fans into different types
    vent_fans[:mech_preheat] = vent_fans[:mech].select { |vent_mech| (not vent_mech.preheating_efficiency_cop.nil?) }
    vent_fans[:mech_precool] = vent_fans[:mech].select { |vent_mech| (not vent_mech.precooling_efficiency_cop.nil?) }
    vent_fans[:mech_supply] = vent_fans[:mech].select { |vent_mech| vent_mech.fan_type == HPXML::MechVentTypeSupply }
    vent_fans[:mech_exhaust] = vent_fans[:mech].select { |vent_mech| vent_mech.fan_type == HPXML::MechVentTypeExhaust }
    vent_fans[:mech_cfis] = vent_fans[:mech].select { |vent_mech| vent_mech.fan_type == HPXML::MechVentTypeCFIS }
    vent_fans[:mech_balanced] = vent_fans[:mech].select { |vent_mech| vent_mech.fan_type == HPXML::MechVentTypeBalanced }
    vent_fans[:mech_erv_hrv] = vent_fans[:mech].select { |vent_mech| [HPXML::MechVentTypeERV, HPXML::MechVentTypeHRV].include? vent_mech.fan_type }

    # Non-CFIS fan power
    house_fan_unavailable_periods = Schedule.get_unavailable_periods(runner, SchedulesFile::Columns[:HouseFan].name, hpxml_header.unavailable_periods)
    add_ee_for_vent_fan_power(model, spaces, Constants::ObjectTypeMechanicalVentilationHouseFan,
                              vent_fans[:mech_supply], vent_fans[:mech_exhaust], vent_fans[:mech_balanced], vent_fans[:mech_erv_hrv], house_fan_unavailable_periods)

    # CFIS fan power
    cfis_fan_actuator = add_ee_for_vent_fan_power(model, spaces, Constants::ObjectTypeMechanicalVentilationHouseFanCFIS) # Fan heat enters space

    # CFIS supplemental fan power
    if not vent_fans[:cfis_suppl].empty?
      vent_mech_cfis_suppl_sup_tot = vent_fans[:cfis_suppl].select { |vent_mech| vent_mech.fan_type == HPXML::MechVentTypeSupply }
      vent_mech_cfis_suppl_exh_tot = vent_fans[:cfis_suppl].select { |vent_mech| vent_mech.fan_type == HPXML::MechVentTypeExhaust }
      cfis_suppl_fan_actuator = add_ee_for_vent_fan_power(model, spaces, Constants::ObjectTypeMechanicalVentilationHouseFanCFISSupplFan,
                                                          vent_mech_cfis_suppl_sup_tot, vent_mech_cfis_suppl_exh_tot)
    else
      cfis_suppl_fan_actuator = nil
    end

    # Calculate effectiveness for all ERV/HRV and store results in a hash
    hrv_erv_effectiveness_map = calc_hrv_erv_effectiveness(vent_fans[:mech_erv_hrv])

    infil_flow = OpenStudio::Model::SpaceInfiltrationDesignFlowRate.new(model)
    infil_flow.setName(Constants::ObjectTypeInfiltration + ' flow')
    infil_flow.setSchedule(model.alwaysOnDiscreteSchedule)
    infil_flow.setSpace(spaces[HPXML::LocationConditionedSpace])
    infil_flow_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(infil_flow, *EPlus::EMSActuatorZoneInfiltrationFlowRate)
    infil_flow_actuator.setName("#{infil_flow.name} act")
    infil_flow.additionalProperties.setFeature('ObjectType', Constants::ObjectTypeInfiltration)

    # Conditioned Space Infiltration Calculation/Program
    infil_program = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
    infil_program.additionalProperties.setFeature('ObjectType', Constants::ObjectTypeInfiltration)
    infil_program.setName(Constants::ObjectTypeInfiltration + ' program')

    # Calculate infiltration without adjustment by ventilation
    apply_infiltration_to_conditioned(spaces, hpxml_bldg, hpxml_header, infil_program, weather, infil_values, sensors)

    # Common variable and load actuators across multiple mech vent calculations, create only once
    fan_sens_load_actuator, fan_lat_load_actuator = setup_mech_vent_vars_actuators(model, spaces, infil_program, sensors)

    # Apply CFIS
    infil_program.addLine("Set #{cfis_fan_actuator.name} = 0.0")
    infil_program.addLine("Set #{cfis_suppl_fan_actuator.name} = 0.0") unless cfis_suppl_fan_actuator.nil?
    apply_cfis(runner, infil_program, vent_fans[:mech_cfis], cfis_data, cfis_fan_actuator, cfis_suppl_fan_actuator, fan_data)

    # Calculate combined air exchange (infiltration and mechanical ventilation)
    apply_infiltration_adjustment_to_conditioned(runner, model, spaces, hpxml_bldg, hpxml_header, infil_program, vent_fans, duct_lk_imbals,
                                                 infil_flow_actuator, schedules_file)

    # Address load of Qfan (Qload)
    # Qload as variable for tracking outdoor air flow rate, excluding recirculation
    infil_program.addLine('Set Qload = Qfan')
    vent_fans[:mech].each do |f|
      recirc_flow_rate = f.average_unit_flow_rate - f.average_oa_unit_flow_rate
      next unless recirc_flow_rate > 0

      # Subtract recirculation air flow rate from Qfan, only come from supply side as exhaust is not allowed to have recirculation
      infil_program.addLine("Set Qload = Qload - #{UnitConversions.convert(recirc_flow_rate, 'cfm', 'm^3/s').round(4)}")
    end
    calculate_fan_loads(infil_program, vent_fans[:mech_erv_hrv], hrv_erv_effectiveness_map, fan_sens_load_actuator, fan_lat_load_actuator, 'Qload')

    # Address preconditioning
    calculate_precond_loads(model, spaces, infil_program, vent_fans, hrv_erv_effectiveness_map, fan_sens_load_actuator, fan_lat_load_actuator, clg_ssn_sensor)

    program_calling_manager = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
    program_calling_manager.setName("#{infil_program.name} calling manager")
    program_calling_manager.setCallingPoint('BeginZoneTimestepAfterInitHeatBalance')
    program_calling_manager.addProgram(infil_program)
  end

  # TODO
  #
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param hpxml_header [HPXML::Header] HPXML Header object (one per HPXML file)
  # @param infil_program [TODO] TODO
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param infil_values [Hash] TODO
  # @param sensors [Hash] Map of :sensor_types => EMS sensors
  # @return [nil]
  def self.apply_infiltration_to_conditioned(spaces, hpxml_bldg, hpxml_header, infil_program, weather, infil_values, sensors)
    site_ap = hpxml_bldg.site.additional_properties

    if hpxml_header.apply_ashrae140_assumptions
      const_ach = infil_values[:nach] * infil_values[:a_ext]
    else
      ach50 = infil_values[:ach50] * infil_values[:a_ext]
    end

    if ach50.to_f > 0
      # Based on "Field Validation of Algebraic Equations for Stack and
      # Wind Driven Air Infiltration Calculations" by Walker and Wilson (1998)

      p_atm = UnitConversions.convert(Psychrometrics.Pstd_fZ(hpxml_bldg.elevation), 'psi', 'atm')
      outside_air_density = UnitConversions.convert(p_atm, 'atm', 'Btu/ft^3') / (Gas.Air.r * UnitConversions.convert(weather.data.AnnualAvgDrybulb, 'F', 'R'))

      n_i = InfilPressureExponent
      cfa = hpxml_bldg.building_construction.conditioned_floor_area
      conditioned_sla = get_infiltration_SLA_from_ACH50(ach50, n_i, cfa, infil_values[:volume]) # Calculate SLA
      a_o = conditioned_sla * cfa # Effective Leakage Area (ft2)

      # Flow Coefficient (cfm/inH2O^n) (based on ASHRAE HoF)
      inf_conv_factor = 776.25 # [ft/min]/[inH2O^(1/2)*ft^(3/2)/lbm^(1/2)]
      delta_pref = 0.016 # inH2O
      c_i = a_o * (2.0 / outside_air_density)**0.5 * delta_pref**(0.5 - n_i) * inf_conv_factor

      if hpxml_bldg.air_infiltration.has_flue_or_chimney_in_conditioned_space
        y_i = 0.2 # Fraction of leakage through the flue; 0.2 is a "typical" value according to THE ALBERTA AIR INFIL1RATION MODEL, Walker and Wilson, 1990
        s_wflue = 1.0 # Flue Shelter Coefficient
      else
        y_i = 0.0 # Fraction of leakage through the flue
        s_wflue = 0.0 # Flue Shelter Coefficient
      end

      # Leakage distributions per Iain Walker (LBL) recommendations
      if not spaces[HPXML::LocationCrawlspaceVented].nil?
        # 15% ceiling, 35% walls, 50% floor leakage distribution for vented crawl
        leakage_ceiling = 0.15
        leakage_floor = 0.50
      else
        # 25% ceiling, 50% walls, 25% floor leakage distribution for slab/basement/unvented crawl
        leakage_ceiling = 0.25
        leakage_floor = 0.25
      end

      r_i = (leakage_ceiling + leakage_floor)
      x_i = (leakage_ceiling - leakage_floor)
      r_i *= (1 - y_i)
      x_i *= (1 - y_i)

      # Calculate Stack Coefficient
      m_o = (x_i + (2.0 * n_i + 1.0) * y_i)**2.0 / (2 - r_i)
      if m_o <=  1.0
        m_i = m_o # eq. 10
      else
        m_i = 1.0 # eq. 11
      end
      if hpxml_bldg.air_infiltration.has_flue_or_chimney_in_conditioned_space
        ncfl_ag = hpxml_bldg.building_construction.number_of_conditioned_floors_above_grade
        if ncfl_ag <= 0
          z_f = 1.0
        else
          z_f = (ncfl_ag + 0.5) / ncfl_ag # Typical value is 1.5 according to THE ALBERTA AIR INFIL1RATION MODEL, Walker and Wilson, 1990, presumably for a single story home
        end
        x_c = r_i + (2.0 * (1.0 - r_i - y_i)) / (n_i + 1.0) - 2.0 * y_i * (z_f - 1.0)**n_i # Critical value of ceiling-floor leakage difference where the neutral level is located at the ceiling (eq. 13)
        f_i = n_i * y_i * (z_f - 1.0)**((3.0 * n_i - 1.0) / 3.0) * (1.0 - (3.0 * (x_c - x_i)**2.0 * r_i**(1 - n_i)) / (2.0 * (z_f + 1.0))) # Additive flue function, Eq. 12
      else
        f_i = 0.0 # Additive flue function (eq. 12)
      end
      f_s = ((1.0 + n_i * r_i) / (n_i + 1.0)) * (0.5 - 0.5 * m_i**1.2)**(n_i + 1.0) + f_i
      stack_coef = f_s * (UnitConversions.convert(outside_air_density * Gravity * infil_values[:height], 'lbm/(ft*s^2)', 'inH2O') / UnitConversions.convert(AssumedInsideTemp, 'F', 'R'))**n_i # inH2O^n/R^n

      # Calculate wind coefficient
      if not spaces[HPXML::LocationCrawlspaceVented].nil?
        if x_i > 1.0 - 2.0 * y_i
          # Critical floor to ceiling difference above which f_w does not change (eq. 25)
          x_i = 1.0 - 2.0 * y_i
        end
        r_x = 1.0 - r_i * (n_i / 2.0 + 0.2) # Redefined R for wind calculations for houses with crawlspaces (eq. 21)
        y_x = 1.0 - y_i / 4.0 # Redefined Y for wind calculations for houses with crawlspaces (eq. 22)
        x_s = (1.0 - r_i) / 5.0 - 1.5 * y_i # Used to calculate X_x (eq.24)
        x_x = 1.0 - (((x_i - x_s) / (2.0 - r_i))**2.0)**0.75 # Redefined X for wind calculations for houses with crawlspaces (eq. 23)
        f_w = 0.19 * (2.0 - n_i) * x_x * r_x * y_x # Wind factor (eq. 20)
      else
        j_i = (x_i + r_i + 2.0 * y_i) / 2.0
        f_w = 0.19 * (2.0 - n_i) * (1.0 - ((x_i + r_i) / 2.0)**(1.5 - y_i)) - y_i / 4.0 * (j_i - 2.0 * y_i * j_i**4.0)
      end
      wind_coef = f_w * UnitConversions.convert(outside_air_density / 2.0, 'lbm/ft^3', 'inH2O/mph^2')**n_i # inH2O^n/mph^2n

      infil_program.addLine("Set p_m = #{site_ap.ashrae_terrain_exponent}")
      infil_program.addLine("Set p_s = #{site_ap.ashrae_site_terrain_exponent}")
      infil_program.addLine("Set s_m = #{site_ap.ashrae_terrain_thickness}")
      infil_program.addLine("Set s_s = #{site_ap.ashrae_site_terrain_thickness}")
      infil_program.addLine("Set z_m = #{UnitConversions.convert(site_ap.height, 'ft', 'm')}")
      infil_program.addLine("Set z_s = #{UnitConversions.convert(infil_values[:height] + [hpxml_bldg.building_construction.unit_height_above_grade, 0].max, 'ft', 'm')}")
      infil_program.addLine('Set f_t = (((s_m/z_m)^p_m)*((z_s/s_s)^p_s))')
      infil_program.addLine("Set Tdiff = #{sensors[:t_in].name}-#{sensors[:t_out].name}")
      infil_program.addLine('Set dT = @Abs Tdiff')
      infil_program.addLine("Set c = #{((UnitConversions.convert(c_i, 'cfm', 'm^3/s') / (UnitConversions.convert(1.0, 'inH2O', 'Pa')**n_i))).round(4)}")
      infil_program.addLine("Set Cs = #{(stack_coef * (UnitConversions.convert(1.0, 'inH2O/R', 'Pa/K')**n_i)).round(4)}")
      infil_program.addLine("Set Cw = #{(wind_coef * (UnitConversions.convert(1.0, 'inH2O/mph^2', 'Pa*s^2/m^2')**n_i)).round(4)}")
      infil_program.addLine("Set n = #{n_i}")
      infil_program.addLine("Set sft = (f_t*#{(site_ap.aim2_shelter_coeff * (1.0 - y_i)) + (s_wflue * (1.5 * y_i))})")
      infil_program.addLine("Set temp1 = ((c*Cw)*((sft*#{sensors[:v_wind].name})^(2*n)))^2")
      infil_program.addLine('Set Qinf = (((c*Cs*(dT^n))^2)+temp1)^0.5')
      infil_program.addLine('Set Qinf = (@Max Qinf 0)')

    elsif const_ach.to_f > 0
      infil_program.addLine("Set Qinf = #{const_ach * UnitConversions.convert(infil_values[:volume], 'ft^3', 'm^3') / UnitConversions.convert(1.0, 'hr', 's')}")
    else
      infil_program.addLine('Set Qinf = 0')
    end
  end

  # TODO
  #
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param hor_lk_frac [TODO] TODO
  # @param neutral_level [TODO] TODO
  # @param space [OpenStudio::Model::Space] an OpenStudio::Model::Space object
  # @param space_height [TODO] TODO
  # @return [TODO] TODO
  def self.calc_wind_stack_coeffs(hpxml_bldg, hor_lk_frac, neutral_level, space, space_height = nil)
    site_ap = hpxml_bldg.site.additional_properties
    if space_height.nil?
      space_height = Geometry.get_height_of_spaces(spaces: [space])
    end
    coord_z = Geometry.get_z_origin_for_zone(space.thermalZone.get)
    f_t_SG = site_ap.site_terrain_multiplier * ((space_height + coord_z) / 32.8)**site_ap.site_terrain_exponent / (site_ap.terrain_multiplier * (site_ap.height / 32.8)**site_ap.terrain_exponent)
    f_s_SG = 2.0 / 3.0 * (1 + hor_lk_frac / 2.0) * (2.0 * neutral_level * (1.0 - neutral_level))**0.5 / (neutral_level**0.5 + (1.0 - neutral_level)**0.5)
    f_w_SG = site_ap.s_g_shielding_coef * (1.0 - hor_lk_frac)**(1.0 / 3.0) * f_t_SG
    c_s_SG = f_s_SG**2.0 * Gravity * space_height / UnitConversions.convert(AssumedInsideTemp, 'F', 'R')
    c_w_SG = f_w_SG**2.0
    return c_w_SG, c_s_SG
  end

  # Returns infiltration normalized leakage given SLA.
  #
  # @param sla [TODO] TODO
  # @param infil_height [Double] Vertical distance between the lowest and highest above-grade points within the pressure boundary, per ASHRAE 62.2 (ft2)
  # @return [TODO] TODO
  def self.get_infiltration_NL_from_SLA(sla, infil_height)
    return 1000.0 * sla * (infil_height / 8.202)**0.4
  end

  # Returns the infiltration annual average ACH given a SLA.
  #
  # @param sla [TODO] TODO
  # @param infil_height [Double] Vertical distance between the lowest and highest above-grade points within the pressure boundary, per ASHRAE 62.2 (ft2)
  # @param weather [WeatherFile] Weather object containing EPW information
  # @return [TODO] TODO
  def self.get_infiltration_ACH_from_SLA(sla, infil_height, weather)
    # Equation from RESNET 380-2016 Equation 9
    norm_leakage = get_infiltration_NL_from_SLA(sla, infil_height)

    # Equation from ASHRAE 136-1993
    return norm_leakage * weather.data.WSF
  end

  # Returns the infiltration SLA given an annual average ACH.
  #
  # @param ach [TODO] TODO
  # @param infil_height [Double] Vertical distance between the lowest and highest above-grade points within the pressure boundary, per ASHRAE 62.2 (ft2)
  # @param avg_ceiling_height [Double] Average floor to ceiling height within conditioned space (ft2)
  # @param weather [WeatherFile] Weather object containing EPW information
  # @return [TODO] TODO
  def self.get_infiltration_SLA_from_ACH(ach, infil_height, avg_ceiling_height, weather)
    return ach * (avg_ceiling_height / 8.202) / (weather.data.WSF * 1000 * (infil_height / 8.202)**0.4)
  end

  # Returns the infiltration SLA given a ACH50.
  #
  # @param ach50 [TODO] TODO
  # @param n_i [TODO] TODO
  # @param floor_area [TODO] TODO
  # @param volume [TODO] TODO
  # @return [TODO] TODO
  def self.get_infiltration_SLA_from_ACH50(ach50, n_i, floor_area, volume)
    return ((ach50 * 0.283316 * 4.0**n_i * volume) / (floor_area * UnitConversions.convert(1.0, 'ft^2', 'in^2') * 50.0**n_i * 60.0))
  end

  # Returns the infiltration ACH50 given a SLA.
  #
  # @param sla [TODO] TODO
  # @param n_i [TODO] TODO
  # @param floor_area [TODO] TODO
  # @param volume [TODO] TODO
  # @return [TODO] TODO
  def self.get_infiltration_ACH50_from_SLA(sla, n_i, floor_area, volume)
    return ((sla * floor_area * UnitConversions.convert(1.0, 'ft^2', 'in^2') * 50.0**n_i * 60.0) / (0.283316 * 4.0**n_i * volume))
  end

  # Returns the effective annual average infiltration rate in cfm.
  #
  # @param nl [TODO] TODO
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param cfa [Double] Conditioned floor area in the dwelling unit (ft2)
  # @return [TODO] TODO
  def self.get_infiltration_Qinf_from_NL(nl, weather, cfa)
    return nl * weather.data.WSF * cfa * 8.202 / 60.0
  end

  # TODO
  #
  # @param q_old [TODO] TODO
  # @param p_old [TODO] TODO
  # @param p_new [TODO] TODO
  # @return [TODO] TODO
  def self.calc_duct_leakage_at_diff_pressure(q_old, p_old, p_new)
    return q_old * (p_new / p_old)**0.6 # Derived from Equation C-1 (Annex C), p34, ASHRAE Standard 152-2004.
  end

  # TODO
  #
  # @param n_i [TODO] TODO
  # @param q_old [TODO] TODO
  # @param p_old [TODO] TODO
  # @param p_new [TODO] TODO
  # @return [TODO] TODO
  def self.calc_air_leakage_at_diff_pressure(n_i, q_old, p_old, p_new)
    return q_old * (p_new / p_old)**n_i
  end

  # TODO
  #
  # @param r_nominal [TODO] TODO
  # @param side [TODO] TODO
  # @param buried_level [TODO] TODO
  # @param f_rect [TODO] TODO
  # @return [TODO] TODO
  def self.get_duct_effective_r_value(r_nominal, side, buried_level, f_rect)
    if buried_level == HPXML::DuctBuriedInsulationNone
      if r_nominal <= 0
        # Uninsulated ducts are set to R-1.7 based on ASHRAE HOF and the above paper.
        return 1.7
      else
        # Insulated duct equations based on "True R-Values of Round Residential Ductwork"
        # by Palmiter & Kruse 2006.
        if side == HPXML::DuctTypeSupply
          d_round = 6.0 # in, assumed average diameter
        elsif side == HPXML::DuctTypeReturn
          d_round = 14.0 # in, assumed average diameter
        end
        f_round = 1.0 - f_rect # Fraction of duct length for round ducts (not rectangular)
        r_ext = 0.667 # Exterior film R-value
        r_int_rect = 0.333 # Interior film R-value for rectangular ducts
        r_int_round = 0.3429 * (d_round**0.1974) # Interior film R-value for round ducts
        k_ins = 2.8 # Thermal resistivity of duct insulation (R-value per inch, assumed fiberglass)
        t = r_nominal / k_ins # Duct insulation thickness
        r_actual = r_nominal / t * (d_round / 2.0) * Math::log(1.0 + (2.0 * t) / d_round) # Actual R-value for round duct
        r_rect = r_int_rect + r_nominal + r_ext # Total R-value for rectangular ducts, including air films
        r_round = r_int_round + r_actual + r_ext * (d_round / (d_round + 2 * t)) # Total R-value for round ducts, including air films
        r_effective = 1.0 / (f_rect / r_rect + f_round / r_round) # Combined effective R-value
        return r_effective.round(2)
      end
    else
      if side == HPXML::DuctTypeSupply
        # Equations derived from Table 13 in https://www.nrel.gov/docs/fy13osti/55876.pdf
        # assuming 6-in supply diameter
        if buried_level == HPXML::DuctBuriedInsulationPartial
          return (4.28 + 0.65 * r_nominal).round(2)
        elsif buried_level == HPXML::DuctBuriedInsulationFull
          return (6.22 + 0.89 * r_nominal).round(2)
        elsif buried_level == HPXML::DuctBuriedInsulationDeep
          return (13.41 + 0.63 * r_nominal).round(2)
        end
      elsif side == HPXML::DuctTypeReturn
        # Equations derived from Table 13 in https://www.nrel.gov/docs/fy13osti/55876.pdf
        # assuming 14-in return diameter
        if buried_level == HPXML::DuctBuriedInsulationPartial
          return (4.62 + 1.31 * r_nominal).round(2)
        elsif buried_level == HPXML::DuctBuriedInsulationFull
          return (8.91 + 1.29 * r_nominal).round(2)
        elsif buried_level == HPXML::DuctBuriedInsulationDeep
          return (18.64 + 1.0 * r_nominal).round(2)
        end
      end
    end
  end

  # Returns Qtot cfm per ASHRAE 62.2.
  #
  # @param nbeds [Integer] Number of bedrooms in the dwelling unit
  # @param cfa [Double] Conditioned floor area in the dwelling unit (ft2)
  # @return [TODO] TODO
  def self.get_mech_vent_qtot_cfm(nbeds, cfa)
    return (nbeds + 1.0) * 7.5 + 0.03 * cfa
  end

  # TODO
  #
  # @param q_tot [TODO] TODO
  # @param q_inf [TODO] TODO
  # @param is_balanced [TODO] TODO
  # @param frac_imbal [TODO] TODO
  # @param a_ext [TODO] TODO
  # @param bldg_type [TODO] TODO
  # @param eri_version [String] Version of the ANSI/RESNET/ICC 301 Standard to use for equations/assumptions
  # @param hours_in_operation [TODO] TODO
  # @return [TODO] TODO
  def self.get_mech_vent_qfan_cfm(q_tot, q_inf, is_balanced, frac_imbal, a_ext, bldg_type, eri_version, hours_in_operation)
    q_inf_eff = q_inf * a_ext
    if Constants::ERIVersions.index(eri_version) >= Constants::ERIVersions.index('2022')
      if frac_imbal == 0
        q_fan = q_tot - q_inf_eff
      else
        q_inf_eff = q_inf * a_ext
        if q_inf_eff >= q_tot
          q_fan = 0.0
        else
          q_fan = ((frac_imbal**2.0 * q_tot**2.0 - 4.0 * frac_imbal * q_inf_eff**2.0 + 2.0 * frac_imbal * q_inf_eff * q_tot + q_inf_eff**2.0)**0.5 + frac_imbal * q_tot - q_inf_eff) / (2.0 * frac_imbal)
        end
      end
    elsif Constants::ERIVersions.index(eri_version) >= Constants::ERIVersions.index('2019')
      if is_balanced
        phi = 1.0
      else
        phi = q_inf / q_tot
      end
      q_fan = q_tot - phi * q_inf_eff
    else
      if [HPXML::ResidentialTypeApartment, HPXML::ResidentialTypeSFA].include? bldg_type
        # No infiltration credit for attached/multifamily
        return q_tot
      end

      if q_inf > 2.0 / 3.0 * q_tot
        q_fan = q_tot - 2.0 / 3.0 * q_tot
      else
        q_fan = q_tot - q_inf
      end
    end

    # Convert from hourly average requirement to actual fan flow rate
    if not hours_in_operation.nil?
      q_fan *= 24.0 / hours_in_operation
    end

    return [q_fan, 0.0].max
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param airloop_map [Hash] Map of HPXML System ID => OpenStudio AirLoopHVAC (or ZoneHVACFourPipeFanCoil or ZoneHVACBaseboardConvectiveWater) objects
  # @return [TODO] TODO
  def self.create_duct_systems(model, spaces, hpxml_bldg, airloop_map)
    duct_systems = {}
    hpxml_bldg.hvac_distributions.each do |hvac_distribution|
      next unless hvac_distribution.distribution_system_type == HPXML::HVACDistributionTypeAir

      air_ducts = create_ducts(model, hvac_distribution, spaces)
      next if air_ducts.empty?

      # Connect AirLoopHVACs to ducts
      added_ducts = false
      hvac_distribution.hvac_systems.each do |hvac_system|
        next if airloop_map[hvac_system.id].nil?

        object = airloop_map[hvac_system.id]
        if duct_systems[air_ducts].nil?
          duct_systems[air_ducts] = object
          added_ducts = true
        elsif duct_systems[air_ducts] != object
          # Multiple air loops associated with this duct system, treat
          # as separate duct systems.
          air_ducts2 = create_ducts(model, hvac_distribution, spaces)
          duct_systems[air_ducts2] = object
          added_ducts = true
        end
      end
      if not added_ducts
        fail 'Unexpected error adding ducts to model.'
      end
    end
    return duct_systems
  end

  # TODO
  #
  # @param model [OpenStudio::Model::Model] OpenStudio Model object
  # @param hvac_distribution [HPXML::HVACDistribution] HPXML HVAC Distribution object
  # @param spaces [Hash] Map of HPXML locations => OpenStudio Space objects
  # @return [Array<Duct>] list of initialized Duct class objects from the airflow resource file
  def self.create_ducts(model, hvac_distribution, spaces)
    air_ducts = []

    # Duct leakage (supply/return => [value, units])
    leakage_to_outside = { HPXML::DuctTypeSupply => [0.0, nil],
                           HPXML::DuctTypeReturn => [0.0, nil] }
    hvac_distribution.duct_leakage_measurements.each do |duct_leakage_measurement|
      next unless [HPXML::UnitsCFM25, HPXML::UnitsCFM50, HPXML::UnitsPercent].include?(duct_leakage_measurement.duct_leakage_units) && (duct_leakage_measurement.duct_leakage_total_or_to_outside == 'to outside')
      next if duct_leakage_measurement.duct_type.nil?

      leakage_to_outside[duct_leakage_measurement.duct_type] = [duct_leakage_measurement.duct_leakage_value, duct_leakage_measurement.duct_leakage_units]
    end

    # Duct location, R-value, Area
    total_unconditioned_duct_area = { HPXML::DuctTypeSupply => 0.0,
                                      HPXML::DuctTypeReturn => 0.0 }
    hvac_distribution.ducts.each do |ducts|
      next if HPXML::conditioned_locations_this_unit.include? ducts.duct_location
      next if ducts.duct_type.nil?

      # Calculate total duct area in unconditioned spaces
      total_unconditioned_duct_area[ducts.duct_type] += ducts.duct_surface_area * ducts.duct_surface_area_multiplier
    end

    # Create duct objects
    hvac_distribution.ducts.each do |ducts|
      next if HPXML::conditioned_locations_this_unit.include? ducts.duct_location
      next if ducts.duct_type.nil?
      next if total_unconditioned_duct_area[ducts.duct_type] <= 0

      duct_loc_space, duct_loc_schedule = Geometry.get_space_or_schedule_from_location(ducts.duct_location, model, spaces)

      # Apportion leakage to individual ducts by surface area
      duct_leakage_value = leakage_to_outside[ducts.duct_type][0] * ducts.duct_surface_area * ducts.duct_surface_area_multiplier / total_unconditioned_duct_area[ducts.duct_type]
      duct_leakage_units = leakage_to_outside[ducts.duct_type][1]

      duct_leakage_frac = nil
      if duct_leakage_units == HPXML::UnitsCFM25
        duct_leakage_cfm25 = duct_leakage_value
      elsif duct_leakage_units == HPXML::UnitsCFM50
        duct_leakage_cfm50 = duct_leakage_value
      elsif duct_leakage_units == HPXML::UnitsPercent
        duct_leakage_frac = duct_leakage_value
      else
        fail "#{ducts.duct_type.capitalize} ducts exist but leakage was not specified for distribution system '#{hvac_distribution.id}'."
      end

      air_ducts << Duct.new(ducts.duct_type, duct_loc_space, duct_loc_schedule, duct_leakage_frac, duct_leakage_cfm25, duct_leakage_cfm50,
                            ducts.duct_surface_area * ducts.duct_surface_area_multiplier, ducts.duct_effective_r_value, ducts.duct_buried_insulation_level)
    end

    # If all ducts are in conditioned space, model leakage as going to outside
    [HPXML::DuctTypeSupply, HPXML::DuctTypeReturn].each do |duct_side|
      next unless (leakage_to_outside[duct_side][0] > 0) && (total_unconditioned_duct_area[duct_side] == 0)

      duct_area = 0.0
      duct_effective_r_value = 99 # arbitrary
      duct_loc_space = nil # outside
      duct_loc_schedule = nil # outside
      duct_leakage_value = leakage_to_outside[duct_side][0]
      duct_leakage_units = leakage_to_outside[duct_side][1]

      if duct_leakage_units == HPXML::UnitsCFM25
        duct_leakage_cfm25 = duct_leakage_value
      elsif duct_leakage_units == HPXML::UnitsCFM50
        duct_leakage_cfm50 = duct_leakage_value
      elsif duct_leakage_units == HPXML::UnitsPercent
        duct_leakage_frac = duct_leakage_value
      else
        fail "#{duct_side.capitalize} ducts exist but leakage was not specified for distribution system '#{hvac_distribution.id}'."
      end

      air_ducts << Duct.new(duct_side, duct_loc_space, duct_loc_schedule, duct_leakage_frac, duct_leakage_cfm25, duct_leakage_cfm50, duct_area,
                            duct_effective_r_value, HPXML::DuctBuriedInsulationNone)
    end

    return air_ducts
  end
end

# TODO
class Duct
  # @param side [TODO] TODO
  # @param loc_space [TODO] TODO
  # @param loc_schedule [TODO] TODO
  # @param leakage_frac [TODO] TODO
  # @param leakage_cfm25 [TODO] TODO
  # @param leakage_cfm50 [TODO] TODO
  # @param area [TODO] TODO
  # @param effective_rvalue [TODO] TODO
  # @param buried_level [TODO] TODO
  def initialize(side, loc_space, loc_schedule, leakage_frac, leakage_cfm25, leakage_cfm50, area, effective_rvalue, buried_level)
    @side = side
    @loc_space = loc_space
    @loc_schedule = loc_schedule
    @leakage_frac = leakage_frac
    @leakage_cfm25 = leakage_cfm25
    @leakage_cfm50 = leakage_cfm50
    @area = area
    @effective_rvalue = effective_rvalue
    @buried_level = buried_level
  end
  attr_accessor(:side, :loc_space, :loc_schedule, :leakage_frac, :leakage_cfm25, :leakage_cfm50, :area, :effective_rvalue, :zone, :location, :buried_level)
end
