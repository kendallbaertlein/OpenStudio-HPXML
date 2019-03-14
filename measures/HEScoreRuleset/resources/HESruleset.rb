require_relative "../../HPXMLtoOpenStudio/resources/airflow"
require_relative "../../HPXMLtoOpenStudio/resources/geometry"
require_relative "../../HPXMLtoOpenStudio/resources/xmlhelper"
require_relative "../../HPXMLtoOpenStudio/resources/hpxml"

class HEScoreRuleset
  def self.apply_ruleset(hpxml_doc)
    orig_details = hpxml_doc.elements["/HPXML/Building/BuildingDetails"]

    # Create new HPXML doc
    hpxml_values = HPXML.get_hpxml_values(hpxml: hpxml_doc.elements["/HPXML"])
    hpxml_values[:eri_calculation_version] = "2014AEG" # FIXME: Verify
    hpxml_doc = HPXML.create_hpxml(**hpxml_values)

    hpxml = hpxml_doc.elements["HPXML"]

    # Global variables
    orig_building_construction_values = HPXML.get_building_construction_values(building_construction: orig_details.elements["BuildingSummary/BuildingConstruction"])
    orig_site_values = HPXML.get_site_values(site: orig_details.elements["BuildingSummary/Site"])
    @year_built = orig_building_construction_values[:year_built]
    @nbeds = orig_building_construction_values[:number_of_bedrooms]
    @cfa = orig_building_construction_values[:conditioned_floor_area] # ft^2
    @ncfl_ag = orig_building_construction_values[:number_of_conditioned_floors_above_grade]
    @ncfl = @ncfl_ag # Number above-grade stories plus any conditioned basement
    if not XMLHelper.get_value(orig_details, "Enclosure/Foundations/Foundation/FoundationType/Basement[Conditioned='true']").nil?
      @ncfl += 1
    end
    @nfl = @ncfl_ag # Number above-grade stories plus any basement
    if not XMLHelper.get_value(orig_details, "Enclosure/Foundations/Foundation/FoundationType/Basement").nil?
      @nfl += 1
    end
    @ceil_height = orig_building_construction_values[:average_ceiling_height] # ft
    @bldg_orient = orig_site_values[:orientation_of_front_of_home]
    @bldg_azimuth = orientation_to_azimuth(@bldg_orient)

    # Calculate geometry
    # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/building-envelope
    # FIXME: Verify. Does this change for shape=townhouse? Maybe ridge changes to front-back instead of left-right
    @cfa_basement = 0.0
    orig_details.elements.each("Enclosure/Foundations/Foundation[FoundationType/Basement[Conditioned='true']]") do |cond_basement|
      @cfa_basement += Float(XMLHelper.get_value(cond_basement, "FrameFloor/Area"))
    end
    @bldg_footprint = (@cfa - @cfa_basement) / @ncfl_ag # ft^2
    @bldg_length_side = (3.0 * @bldg_footprint / 5.0)**0.5 # ft
    @bldg_length_front = (5.0 / 3.0) * @bldg_length_side # ft
    @bldg_perimeter = 2.0 * @bldg_length_front + 2.0 * @bldg_length_side # ft
    @cvolume = @cfa * @ceil_height # ft^3 FIXME: Verify. Should this change for cathedral ceiling, conditioned basement, etc.?
    @height = @ceil_height * @ncfl_ag # ft FIXME: Verify. Used for infiltration.
    @roof_angle = 30.0 # deg

    # BuildingSummary
    set_summary(hpxml)

    # ClimateAndRiskZones
    set_climate(orig_details, hpxml)

    # Enclosure
    set_enclosure_air_infiltration(orig_details, hpxml)
    set_enclosure_attics_roofs(orig_details, hpxml)
    set_enclosure_foundations(orig_details, hpxml)
    set_enclosure_rim_joists(orig_details, hpxml)
    set_enclosure_walls(orig_details, hpxml)
    set_enclosure_windows(orig_details, hpxml)
    set_enclosure_skylights(orig_details, hpxml)
    set_enclosure_doors(orig_details, hpxml)

    # Systems
    set_systems_hvac(orig_details, hpxml)
    set_systems_mechanical_ventilation(orig_details, hpxml)
    set_systems_water_heater(orig_details, hpxml)
    set_systems_water_heating_use(hpxml)
    set_systems_photovoltaics(orig_details, hpxml)

    # Appliances
    set_appliances_clothes_washer(hpxml)
    set_appliances_clothes_dryer(hpxml)
    set_appliances_dishwasher(hpxml)
    set_appliances_refrigerator(hpxml)
    set_appliances_cooking_range_oven(hpxml)

    # Lighting
    set_lighting(orig_details, hpxml)
    set_ceiling_fans(orig_details, hpxml)

    # MiscLoads
    set_misc_plug_loads(hpxml)
    set_misc_television(hpxml)

    return hpxml_doc
  end

  def self.set_summary(hpxml)
    # TODO: Neighboring buildings to left/right, 12ft offset, same height as building; what about townhouses?
    HPXML.add_site(hpxml: hpxml,
                   fuels: ["electricity"], # TODO Check if changing this would ever influence results; if it does, talk to Leo
                   shelter_coefficient: Airflow.get_default_shelter_coefficient())
    HPXML.add_building_occupancy(hpxml: hpxml,
                                 number_of_residents: Geometry.get_occupancy_default_num(@nbeds))
    HPXML.add_building_construction(hpxml: hpxml,
                                    number_of_conditioned_floors: @ncfl,
                                    number_of_conditioned_floors_above_grade: @ncfl_ag,
                                    number_of_bedrooms: @nbeds,
                                    conditioned_floor_area: @cfa,
                                    conditioned_building_volume: @cvolume,
                                    garage_present: false)
  end

  def self.set_climate(orig_details, hpxml)
    HPXML.add_climate_zone_iecc(hpxml: hpxml,
                                year: 2006,
                                climate_zone: "6A") # TODO Get from input

    orig_weather_station = orig_details.elements["ClimateandRiskZones/WeatherStation"]
    orig_name = XMLHelper.get_value(orig_weather_station, "Name")
    orig_wmo = XMLHelper.get_value(orig_weather_station, "WMO")
    HPXML.add_weather_station(hpxml: hpxml,
                              id: "WeatherStation",
                              name: orig_name,
                              wmo: orig_wmo)
  end

  def self.set_enclosure_air_infiltration(orig_details, hpxml)
    cfm50 = XMLHelper.get_value(orig_details, "Enclosure/AirInfiltration/AirInfiltrationMeasurement[HousePressure='50']/BuildingAirLeakage[UnitofMeasure='CFM']/AirLeakage")
    desc = XMLHelper.get_value(orig_details, "Enclosure/AirInfiltration/AirInfiltrationMeasurement/LeakinessDescription")

    if not cfm50.nil?
      ach50 = Float(cfm50) * 60.0 / @cvolume
    else
      iecc_cz = "6A" # FIXME: Get from input when it's available
      ach50 = calc_ach50(@ncfl_ag, @cfa, @height, @cvolume, desc, @year_built, iecc_cz, orig_details)
    end

    HPXML.add_air_infiltration_measurement(hpxml: hpxml,
                                           id: "AirInfiltrationMeasurement",
                                           house_pressure: 50,
                                           unit_of_measure: "ACH",
                                           air_leakage: ach50)
  end

  def self.set_enclosure_attics_roofs(orig_details, hpxml)
    orig_details.elements.each("Enclosure/AtticAndRoof/Attics/Attic") do |orig_attic|
      orig_attic_values = HPXML.get_attic_values(attic: orig_attic)
      orig_roof = get_attached(HPXML.get_idref(orig_attic, "AttachedToRoof"), orig_details, "Enclosure/AtticAndRoof/Roofs/Roof")
      orig_roof_values = HPXML.get_attic_roof_values(roof: orig_roof)
      orig_roof_ins = orig_attic.elements["AtticRoofInsulation"]
      orig_roof_ins_values = HPXML.get_assembly_insulation_values(insulation: orig_roof_ins)
      orig_attic_values[:attic_type] = { "vented attic" => "VentedAttic",
                                         "cape cod" => "ConditionedAttic",
                                         "cathedral ceiling" => "CathedralCeiling" }[XMLHelper.get_value(orig_attic, "AtticType")]

      new_attic = HPXML.add_attic(hpxml: hpxml,
                                  id: orig_attic_values[:id],
                                  attic_type: orig_attic_values[:attic_type])

      # Roof: Two surfaces per HES zone_roof
      roof_r_cavity = Integer(XMLHelper.get_value(orig_attic, "AtticRoofInsulation/Layer[InstallationType='cavity']/NominalRValue"))
      roof_r_cont = XMLHelper.get_value(orig_attic, "AtticRoofInsulation/Layer[InstallationType='continuous']/NominalRValue").to_i
      roof_solar_abs = orig_roof_values[:solar_absorptance]
      roof_solar_abs = get_roof_solar_absorptance(orig_roof_values[:roof_color]) if orig_roof_values[:solar_absorptance].nil?
      roof_r = get_roof_assembly_r(roof_r_cavity, roof_r_cont, orig_roof_values[:roof_type], orig_roof_values[:radiant_barrier])

      roof_azimuths = [@bldg_azimuth, @bldg_azimuth + 180] # FIXME: Verify
      roof_azimuths.each_with_index do |roof_azimuth, idx|
        HPXML.add_attic_roof(attic: new_attic,
                             id: "#{orig_roof_values[:id]}_#{idx}",
                             area: 1000.0 / 2, # FIXME: Hard-coded. Use input if cathedral ceiling or conditioned attic, otherwise calculate default?
                             azimuth: sanitize_azimuth(roof_azimuth),
                             solar_absorptance: roof_solar_abs,
                             emittance: 0.9, # ERI assumption; TODO get values from method
                             pitch: Math.tan(UnitConversions.convert(@roof_angle, "deg", "rad")) * 12,
                             radiant_barrier: false, # FIXME: Verify. Setting to false because it's included in the assembly R-value
                             insulation_id: "#{orig_roof_ins_values[:id]}_#{idx}",
                             insulation_assembly_r_value: roof_r)
      end

      # Floor
      if ["UnventedAttic", "VentedAttic"].include? orig_attic_values[:attic_type]
        floor_r_cavity = Integer(XMLHelper.get_value(orig_attic, "AtticFloorInsulation/Layer[InstallationType='cavity']/NominalRValue"))
        floor_r = get_ceiling_assembly_r(floor_r_cavity)

        orig_floor_ins = orig_attic.elements["AtticFloorInsulation"]
        orig_floor_ins_values = HPXML.get_assembly_insulation_values(insulation: orig_floor_ins)

        HPXML.add_attic_floor(attic: new_attic,
                              id: "#{orig_attic_values[:id]}_floor",
                              adjacent_to: "living space",
                              area: 1000.0, # FIXME: Hard-coded. Use input if vented attic, otherwise calculate default?
                              insulation_id: orig_floor_ins_values[:id],
                              insulation_assembly_r_value: floor_r)
      end

      # Gable wall: Two surfaces per HES zone_roof
      # FIXME: Do we want gable walls even for cathedral ceiling and conditioned attic where roof area is provided by the user?
      gable_height = @bldg_length_side / 2 * Math.sin(UnitConversions.convert(@roof_angle, "deg", "rad"))
      gable_area = @bldg_length_side / 2 * gable_height
      gable_azimuths = [@bldg_azimuth + 90, @bldg_azimuth + 270] # FIXME: Verify
      gable_azimuths.each_with_index do |gable_azimuth, idx|
        HPXML.add_attic_wall(attic: new_attic,
                             id: "#{orig_roof_values[:id]}_gable_#{idx}",
                             adjacent_to: "outside",
                             wall_type: "WoodStud",
                             area: gable_area, # FIXME: Verify
                             azimuth: sanitize_azimuth(gable_azimuth),
                             solar_absorptance: 0.75, # ERI assumption; TODO get values from method
                             emittance: 0.9, # ERI assumption; TODO get values from method
                             insulation_id: "#{orig_roof_values[:id]}_gable_ins_#{idx}",
                             insulation_assembly_r_value: 4.0) # FIXME: Hard-coded
      end

      # Uses ERI Reference Home for vented attic specific leakage area
    end
  end

  def self.set_enclosure_foundations(orig_details, hpxml)
    orig_details.elements.each("Enclosure/Foundations/Foundation") do |orig_foundation|
      orig_foundation_values = HPXML.get_foundation_values(foundation: orig_foundation)
      fnd_type = orig_foundation_values[:foundation_type]

      new_foundation = HPXML.add_foundation(hpxml: hpxml,
                                            id: orig_foundation_values[:id],
                                            foundation_type: fnd_type)

      # FrameFloor
      if ["UnconditionedBasement", "VentedCrawlspace", "UnventedCrawlspace"].include? fnd_type
        orig_framefloor = orig_foundation.elements["FrameFloor"]
        orig_framefloor_values = HPXML.get_frame_floor_values(floor: orig_framefloor)
        floor_r_cavity = Integer(XMLHelper.get_value(orig_foundation, "FrameFloor/Insulation/Layer[InstallationType='cavity']/NominalRValue"))
        floor_r = get_floor_assembly_r(floor_r_cavity)
        insulation_id = orig_framefloor.elements["Insulation/SystemIdentifier"].attributes["id"]

        HPXML.add_frame_floor(foundation: new_foundation,
                              id: orig_framefloor_values[:id],
                              adjacent_to: "living space",
                              area: orig_framefloor_values[:area],
                              insulation_id: insulation_id,
                              insulation_assembly_r_value: floor_r)

      end

      # FoundationWall
      if ["UnconditionedBasement", "ConditionedBasement", "VentedCrawlspace", "UnventedCrawlspace"].include? fnd_type
        orig_fndwall = orig_foundation.elements["FoundationWall"]
        orig_fndwall_values = HPXML.get_foundation_wall_values(foundation_wall: orig_fndwall)
        wall_r = Float(XMLHelper.get_value(orig_foundation, "FoundationWall/Insulation/Layer[InstallationType='continuous']/NominalRValue"))
        insulation_id = orig_fndwall.elements["Insulation/SystemIdentifier"].attributes["id"]

        # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/doe2-inputs-assumptions-and-calculations/the-doe2-model
        if ["UnconditionedBasement", "ConditionedBasement"].include? fnd_type
          wall_height = 8.0 # FIXME: Verify
        else
          wall_height = 2.5 # FIXME: Verify
        end

        HPXML.add_foundation_wall(foundation: new_foundation,
                                  id: orig_fndwall_values[:id],
                                  height: wall_height,
                                  area: wall_height * @bldg_perimeter, # FIXME: Verify
                                  thickness: 8, # FIXME: Verify
                                  depth_below_grade: wall_height, # FIXME: Verify
                                  adjacent_to: "ground",
                                  insulation_id: insulation_id,
                                  insulation_assembly_r_value: wall_r + 3.0) # FIXME: need to convert from insulation R-value to assembly R-value

      end

      # Slab
      if fnd_type == "SlabOnGrade"
        slab_perim_r = Integer(XMLHelper.get_value(orig_foundation, "Slab/PerimeterInsulation/Layer[InstallationType='continuous']/NominalRValue"))
        slab_area = XMLHelper.get_value(orig_foundation, "Slab/Area")
        fnd_id = orig_foundation_values[:id]
        slab_id = orig_foundation.elements["Slab/SystemIdentifier"].attributes["id"]
        slab_perim_id = orig_foundation.elements["Slab/PerimeterInsulation/SystemIdentifier"].attributes["id"]
        slab_under_id = "#{slab_id}_under_insulation"
      else
        slab_perim_r = 0
        slab_area = Float(XMLHelper.get_value(orig_foundation, "FrameFloor/Area"))
        slab_id = "#{orig_foundation_values[:id]}_slab"
        slab_perim_id = "#{slab_id}_perim_insulation"
        slab_under_id = "#{slab_id}_under_insulation"
      end
      HPXML.add_slab(foundation: new_foundation,
                     id: slab_id,
                     area: slab_area,
                     thickness: 4,
                     exposed_perimeter: @bldg_perimeter, # FIXME: Verify
                     perimeter_insulation_depth: 1, # FIXME: Hard-coded
                     under_slab_insulation_width: 0, # FIXME: Verify
                     depth_below_grade: 0, # FIXME: Verify
                     carpet_fraction: 0.5, # FIXME: Hard-coded
                     carpet_r_value: 2, # FIXME: Hard-coded
                     perimeter_insulation_id: slab_perim_id,
                     perimeter_insulation_r_value: slab_perim_r,
                     under_slab_insulation_id: slab_under_id,
                     under_slab_insulation_r_value: 0)

      # Uses ERI Reference Home for vented crawlspace specific leakage area
    end
  end

  def self.set_enclosure_rim_joists(orig_details, hpxml)
    # No rim joists
  end

  def self.set_enclosure_walls(orig_details, hpxml)
    orig_details.elements.each("Enclosure/Walls/Wall") do |orig_wall|
      orig_wall_values = HPXML.get_wall_values(wall: orig_wall)

      wall_type = orig_wall_values[:wall_type]
      wall_orient = orig_wall_values[:orientation]
      wall_area = nil
      if @bldg_orient == wall_orient or @bldg_orient == reverse_orientation(wall_orient)
        wall_area = @ceil_height * @bldg_length_front * @ncfl_ag # FIXME: Verify
      else
        wall_area = @ceil_height * @bldg_length_side * @ncfl_ag # FIXME: Verify
      end

      if wall_type == "WoodStud"
        wall_r_cavity = Integer(XMLHelper.get_value(orig_wall, "Insulation/Layer[InstallationType='cavity']/NominalRValue"))
        wall_r_cont = XMLHelper.get_value(orig_wall, "Insulation/Layer[InstallationType='continuous']/NominalRValue").to_i
        wall_ove = Boolean(XMLHelper.get_value(orig_wall, "WallType/WoodStud/OptimumValueEngineering"))

        wall_r = get_wood_stud_wall_assembly_r(wall_r_cavity, wall_r_cont, orig_wall_values[:siding], wall_ove)
      elsif wall_type == "StructuralBrick"
        wall_r_cont = Integer(XMLHelper.get_value(orig_wall, "Insulation/Layer[InstallationType='continuous']/NominalRValue"))

        wall_r = get_structural_block_wall_assembly_r(wall_r_cont)
      elsif wall_type == "ConcreteMasonryUnit"
        wall_r_cavity = Integer(XMLHelper.get_value(orig_wall, "Insulation/Layer[InstallationType='cavity']/NominalRValue"))

        wall_r = get_concrete_block_wall_assembly_r(wall_r_cavity, orig_wall_values[:siding])
      elsif wall_type == "StrawBale"
        wall_r = get_straw_bale_wall_assembly_r(orig_wall_values[:siding])
      else
        fail "Unexpected wall type '#{wall_type}'."
      end

      orig_wall_ins = orig_wall.elements["Insulation"]
      wall_ins_id = HPXML.get_id(orig_wall_ins)

      HPXML.add_wall(hpxml: hpxml,
                     id: orig_wall_values[:id],
                     exterior_adjacent_to: "outside",
                     interior_adjacent_to: "living space",
                     wall_type: wall_type,
                     area: wall_area,
                     azimuth: orientation_to_azimuth(wall_orient),
                     solar_absorptance: 0.75, # ERI assumption; TODO get values from method
                     emittance: 0.9, # ERI assumption; TODO get values from method
                     insulation_id: wall_ins_id,
                     insulation_assembly_r_value: wall_r)
    end
  end

  def self.set_enclosure_windows(orig_details, hpxml)
    orig_details.elements.each("Enclosure/Windows/Window") do |orig_window|
      orig_window_values = HPXML.get_window_values(window: orig_window)
      win_ufactor = orig_window_values[:ufactor]
      win_shgc = orig_window_values[:shgc]
      win_has_solar_screen = (orig_window_values[:exterior_shading] == "solar screens") # FIXME: Solar screen (add R-0.1 and multiply SHGC by 0.85?)

      if win_ufactor.nil?
        win_frame_type = orig_window_values[:frame_type]
        if win_frame_type == "Aluminum" and Boolean(XMLHelper.get_value(orig_window, "FrameType/Aluminum/ThermalBreak"))
          win_frame_type += "ThermalBreak"
        end

        win_ufactor, win_shgc = get_window_ufactor_shgc(win_frame_type, orig_window_values[:glass_layers], orig_window_values[:glass_type], orig_window_values[:gas_fill])
      end

      # Add one HPXML window per story (for this facade) to accommodate different overhang distances
      window_height = 4.0 # FIXME: Hard-coded
      for story in 1..@ncfl_ag
        HPXML.add_window(hpxml: hpxml,
                         id: "#{orig_window_values[:id]}_story#{story}",
                         area: orig_window_values[:area] / @ncfl_ag,
                         azimuth: orientation_to_azimuth(orig_window_values[:orientation]),
                         ufactor: win_ufactor,
                         shgc: win_shgc,
                         overhangs_depth: 1.0, # FIXME: Verify
                         overhangs_distance_to_top_of_window: 2.0, # FIXME: Hard-coded
                         overhangs_distance_to_bottom_of_window: 6.0, # FIXME: Hard-coded
                         wall_idref: orig_window_values[:wall_idref])
      end
      # Uses ERI Reference Home for interior shading
    end
  end

  def self.set_enclosure_skylights(orig_details, hpxml)
    orig_details.elements.each("Enclosure/Skylights/Skylight") do |orig_skylight|
      orig_skylight_values = HPXML.get_skylight_values(skylight: orig_skylight)
      sky_ufactor = orig_skylight_values[:ufactor]
      sky_shgc = orig_skylight_values[:shgc]
      sky_has_solar_screen = (orig_skylight_values[:exterior_shading] == "solar screens") # FIXME: Solar screen (add R-0.1 and multiply SHGC by 0.85?)

      if sky_ufactor.nil?
        sky_frame_type = orig_skylight_values[:frame_type]
        if sky_frame_type == "Aluminum" and Boolean(XMLHelper.get_value(orig_skylight, "FrameType/Aluminum/ThermalBreak"))
          sky_frame_type += "ThermalBreak"
        end
        sky_ufactor, sky_shgc = get_skylight_ufactor_shgc(sky_frame_type, orig_skylight_values[:glass_layers], orig_skylight_values[:glass_type], orig_skylight_values[:gas_fill])
      end
      
      HPXML.add_skylight(hpxml: hpxml,
                         id: orig_skylight_values[:id],
                         area: orig_skylight_values[:area],
                         azimuth: orientation_to_azimuth(@bldg_orient), # FIXME: Hard-coded
                         ufactor: sky_ufactor,
                         shgc: sky_shgc,
                         roof_idref: "#{orig_skylight_values[:roof_idref]}_0") # FIXME: Hard-coded
      # No overhangs
    end
  end

  def self.set_enclosure_doors(orig_details, hpxml)
    front_wall = nil
    orig_details.elements.each("Enclosure/Walls/Wall") do |orig_wall|
      orig_wall_values = HPXML.get_wall_values(wall: orig_wall)
      next if orig_wall_values[:orientation] != @bldg_orient

      front_wall = orig_wall
    end
    fail "Could not find front wall." if front_wall.nil?

    front_wall_values = HPXML.get_wall_values(wall: front_wall)
    HPXML.add_door(hpxml: hpxml,
                   id: "Door",
                   wall_idref: front_wall_values[:id],
                   azimuth: orientation_to_azimuth(@bldg_orient))
    # Uses ERI Reference Home for Area
    # Uses ERI Reference Home for RValue
  end

  def self.set_systems_hvac(orig_details, hpxml)
    additional_hydronic_ids = []

    # HeatingSystem
    orig_details.elements.each("Systems/HVAC/HVACPlant/HeatingSystem") do |orig_heating|
      orig_heating_values = HPXML.get_heating_system_values(heating_system: orig_heating)

      hvac_type = orig_heating_values[:heating_system_type]
      hvac_fuel = orig_heating_values[:heating_system_fuel]
      hvac_frac = orig_heating_values[:fraction_heat_load_served]
      distribution_system_id = orig_heating_values[:distribution_system_idref]
      if hvac_type == "Boiler" and distribution_system_id.nil?
        # Need to create hydronic distribution system
        distribution_system_id = orig_heating_values[:id] + "_dist"
        additional_hydronic_ids << distribution_system_id
      end
      hvac_units = nil
      hvac_value = nil
      if ["Furnace", "WallFurnace", "Boiler"].include? hvac_type
        hvac_year = orig_heating_values[:year_installed]
        hvac_units = "AFUE"
        hvac_value = XMLHelper.get_value(orig_heating, "AnnualHeatingEfficiency[Units='#{hvac_units}']/Value")
        if not hvac_year.nil?
          if ["Furnace", "WallFurnace"].include? hvac_type
            hvac_value = get_default_furnace_afue(Integer(hvac_year), hvac_fuel)
          else
            hvac_value = get_default_boiler_afue(Integer(hvac_year), hvac_fuel)
          end
        end
      elsif hvac_type == "ElectricResistance"
        hvac_units = "Percent"
        hvac_value = 0.98 # From http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/heating-and-cooling-equipment/heating-and-cooling-equipment-efficiencies
      elsif hvac_type == "Stove"
        hvac_units = "Percent"
        if hvac_fuel == "wood"
          hvac_value = 0.60 # From http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/heating-and-cooling-equipment/heating-and-cooling-equipment-efficiencies
        elsif hvac_fuel == "wood pellets"
          hvac_value = 0.78 # From http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/heating-and-cooling-equipment/heating-and-cooling-equipment-efficiencies
        else
          fail "Unexpected fuel type '#{hvac_fuel}' for stove heating system."
        end
      else
        fail "Unexpected heating system type '#{hvac_type}'."
      end

      HPXML.add_heating_system(hpxml: hpxml,
                               id: orig_heating_values[:id],
                               distribution_system_idref: distribution_system_id,
                               heating_system_type: hvac_type,
                               heating_system_fuel: hvac_fuel,
                               heating_capacity: -1, # Use Manual J auto-sizing
                               heating_efficiency_units: hvac_units,
                               heating_efficiency_value: hvac_value,
                               fraction_heat_load_served: hvac_frac)
    end

    # CoolingSystem
    orig_details.elements.each("Systems/HVAC/HVACPlant/CoolingSystem") do |orig_cooling|
      orig_cooling_values = HPXML.get_cooling_system_values(cooling_system: orig_cooling)

      hvac_type = orig_cooling_values[:cooling_system_type]
      hvac_frac = orig_cooling_values[:fraction_cool_load_served]
      distribution_system_id = orig_cooling_values[:distribution_system_idref]
      hvac_units = nil
      hvac_value = nil
      if hvac_type == "central air conditioning"
        hvac_year = orig_cooling_values[:year_installed]
        hvac_units = "SEER"
        hvac_value = XMLHelper.get_value(orig_cooling, "AnnualCoolingEfficiency[Units='#{hvac_units}']/Value")
        if not hvac_year.nil?
          hvac_value = get_default_central_ac_seer(Integer(hvac_year))
        end
      elsif hvac_type == "room air conditioner"
        hvac_year = orig_cooling_values[:year_installed]
        hvac_units = "EER"
        hvac_value = XMLHelper.get_value(orig_cooling, "AnnualCoolingEfficiency[Units='#{hvac_units}']/Value")
        if not hvac_year.nil?
          hvac_value = get_default_room_ac_eer(Integer(hvac_year))
        end
      else
        fail "Unexpected cooling system type '#{hvac_type}'."
      end

      HPXML.add_cooling_system(hpxml: hpxml,
                               id: orig_cooling_values[:id],
                               distribution_system_idref: distribution_system_id,
                               cooling_system_type: hvac_type,
                               cooling_system_fuel: "electricity",
                               cooling_capacity: -1, # Use Manual J auto-sizing
                               fraction_cool_load_served: hvac_frac,
                               cooling_efficiency_units: hvac_units,
                               cooling_efficiency_value: hvac_value)
    end

    # HeatPump
    orig_details.elements.each("Systems/HVAC/HVACPlant/HeatPump") do |orig_hp|
      orig_hp_values = HPXML.get_heat_pump_values(heat_pump: orig_hp)

      distribution_system_id = nil
      if XMLHelper.has_element(orig_hp, "DistributionSystem")
        distribution_system_id = orig_hp_values[:distribution_system_idref]
      end
      hvac_type = orig_hp_values[:heat_pump_type]
      hvac_frac_heat = orig_hp_values[:fraction_heat_load_served]
      hvac_frac_cool = orig_hp_values[:fraction_cool_load_served]
      hvac_units_heat = nil
      hvac_value_heat = nil
      hvac_units_cool = nil
      hvac_value_cool = nil
      if ["air-to-air", "mini-split"].include? hvac_type
        hvac_year = orig_hp_values[:year_installed]
        hvac_units_cool = "SEER"
        hvac_value_cool = XMLHelper.get_value(orig_hp, "AnnualCoolEfficiency[Units='#{hvac_units_cool}']/Value")
        hvac_units_heat = "HSPF"
        hvac_value_heat = XMLHelper.get_value(orig_hp, "AnnualHeatEfficiency[Units='#{hvac_units_heat}']/Value")
        if not hvac_year.nil?
          hvac_value_cool, hvac_value_heat = get_default_ashp_seer_hspf(Integer(hvac_year))
        end
      elsif hvac_type == "ground-to-air"
        hvac_year = orig_hp_values[:year_installed]
        hvac_units_cool = "EER"
        hvac_value_cool = XMLHelper.get_value(orig_hp, "AnnualCoolEfficiency[Units='#{hvac_units_cool}']/Value")
        hvac_units_heat = "COP"
        hvac_value_heat = XMLHelper.get_value(orig_hp, "AnnualHeatEfficiency[Units='#{hvac_units_heat}']/Value")
        if not hvac_year.nil?
          hvac_value_cool, hvac_value_heat = get_default_gshp_eer_cop(Integer(hvac_year))
        end
      else
        fail "Unexpected peat pump system type '#{hvac_type}'."
      end

      HPXML.add_heat_pump(hpxml: hpxml,
                          id: orig_hp_values[:id],
                          distribution_system_idref: distribution_system_id,
                          heat_pump_type: hvac_type,
                          heat_pump_fuel: "electricity",
                          heating_capacity: -1, # Use Manual J auto-sizing
                          cooling_capacity: -1, # Use Manual J auto-sizing
                          fraction_heat_load_served: hvac_frac_heat,
                          fraction_cool_load_served: hvac_frac_cool,
                          heating_efficiency_units: hvac_units_heat,
                          heating_efficiency_value: hvac_value_heat,
                          cooling_efficiency_units: hvac_units_cool,
                          cooling_efficiency_value: hvac_value_cool)
    end

    # HVACControl
    HPXML.add_hvac_control(hpxml: hpxml,
                           id: "HVACControl",
                           control_type: "manual thermostat")

    # HVACDistribution
    orig_details.elements.each("Systems/HVAC/HVACDistribution") do |orig_dist|
      orig_dist_values = HPXML.get_hvac_distribution_values(hvac_distribution: orig_dist)
      ducts_sealed = orig_dist_values[:duct_system_sealed]

      # Leakage fraction of total air handler flow
      # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/thermal-distribution-efficiency/thermal-distribution-efficiency
      # FIXME: Verify. Total or to the outside?
      # FIXME: Or 10%/25%? See https://docs.google.com/spreadsheets/d/1YeoVOwu9DU-50fxtT_KRh_BJLlchF7nls85Ebe9fDkI/edit#gid=1042407563
      if ducts_sealed
        leakage_frac = 0.03
      else
        leakage_frac = 0.15
      end

      # FIXME: Verify
      # Surface areas outside conditioned space
      # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/thermal-distribution-efficiency/thermal-distribution-efficiency
      supply_duct_area = 0.27 * @cfa
      return_duct_area = 0.05 * @nfl * @cfa

      dist_id = HPXML.get_id(orig_dist)
      new_dist = HPXML.add_hvac_distribution(hpxml: hpxml,
                                             id: dist_id,
                                             distribution_system_type: "AirDistribution")
      new_air_dist = new_dist.elements["DistributionSystemType/AirDistribution"]

      # Supply duct leakage
      HPXML.add_duct_leakage_measurement(air_distribution: new_air_dist,
                                         duct_type: "supply",
                                         duct_leakage_value: 100) # FIXME: Hard-coded

      # Return duct leakage
      HPXML.add_duct_leakage_measurement(air_distribution: new_air_dist,
                                         duct_type: "return",
                                         duct_leakage_value: 100) # FIXME: Hard-coded

      orig_dist.elements.each("DistributionSystemType/AirDistribution/Ducts") do |orig_duct|
        orig_duct_values = HPXML.get_ducts_values(ducts: orig_duct)
        hpxml_v23_to_v30_map = { "conditioned space" => "living space",
                                 "unconditioned basement" => "basement - unconditioned",
                                 "unvented crawlspace" => "crawlspace - unvented",
                                 "vented crawlspace" => "crawlspace - vented",
                                 "unconditioned attic" => "attic - vented" } # FIXME: Change to "attic - unconditioned"
        duct_location = orig_duct_values[:duct_location]
        duct_insulated = orig_duct_values[:hescore_ducts_insulated]

        # FIXME: Verify nominal insulation and not assembly
        if duct_insulated
          duct_rvalue = 6
        else
          duct_rvalue = 0
        end

        # Supply duct
        HPXML.add_ducts(air_distribution: new_air_dist,
                        duct_type: "supply",
                        duct_insulation_r_value: duct_rvalue,
                        duct_location: hpxml_v23_to_v30_map[duct_location],
                        duct_surface_area: orig_duct_values[:duct_fraction_area] * supply_duct_area)

        # Return duct
        HPXML.add_ducts(air_distribution: new_air_dist,
                        duct_type: "return",
                        duct_insulation_r_value: duct_rvalue,
                        duct_location: hpxml_v23_to_v30_map[duct_location],
                        duct_surface_area: orig_duct_values[:duct_fraction_area] * return_duct_area)
      end
    end

    additional_hydronic_ids.each do |hydronic_id|
      HPXML.add_hvac_distribution(hpxml: hpxml,
                                  id: hydronic_id,
                                  distribution_system_type: "HydronicDistribution")
    end
  end

  def self.set_systems_mechanical_ventilation(orig_details, hpxml)
    # No mechanical ventilation
  end

  def self.set_systems_water_heater(orig_details, hpxml)
    orig_details.elements.each("Systems/WaterHeating/WaterHeatingSystem") do |orig_wh_sys|
      orig_wh_sys_values = HPXML.get_water_heating_system_values(water_heating_system: orig_wh_sys)
      wh_year = orig_wh_sys_values[:year_installed]
      wh_ef = orig_wh_sys_values[:energy_factor]
      wh_uef = orig_wh_sys_values[:uniform_energy_factor]
      wh_fuel = orig_wh_sys_values[:fuel_type]
      wh_type = orig_wh_sys_values[:water_heater_type]

      if not wh_year.nil?
        wh_ef = get_default_water_heater_ef(Integer(wh_year), wh_fuel)
      end

      wh_capacity = nil
      if wh_type == "storage water heater"
        wh_capacity = get_default_water_heater_capacity(wh_fuel)
      end
      wh_recovery_efficiency = nil
      if wh_type == "storage water heater" and wh_fuel != "electricity"
        wh_recovery_efficiency = get_default_water_heater_re(wh_fuel)
      end
      wh_tank_volume = nil
      if wh_type != "instantaneous water heater"
        wh_tank_volume = get_default_water_heater_volume(wh_fuel)
      end
      HPXML.add_water_heating_system(hpxml: hpxml,
                                     id: orig_wh_sys_values[:id],
                                     fuel_type: wh_fuel,
                                     water_heater_type: wh_type,
                                     location: "living space", # FIXME: To be decided later
                                     tank_volume: wh_tank_volume,
                                     fraction_dhw_load_served: 1.0,
                                     heating_capacity: wh_capacity,
                                     energy_factor: wh_ef,
                                     uniform_energy_factor: wh_uef,
                                     recovery_efficiency: wh_recovery_efficiency)
    end
  end

  def self.set_systems_water_heating_use(hpxml)
    HPXML.add_hot_water_distribution(hpxml: hpxml,
                                     id: "HotWaterDistribution",
                                     system_type: "Standard",
                                     pipe_r_value: 0)

    HPXML.add_water_fixture(hpxml: hpxml,
                            id: "ShowerHead",
                            water_fixture_type: "shower head",
                            low_flow: false)
  end

  def self.set_systems_photovoltaics(orig_details, hpxml)
    return if not XMLHelper.has_element(orig_details, "Systems/Photovoltaics")

    orig_pv_system_values = HPXML.get_pv_system_values(pv_system: orig_details.elements["Systems/Photovoltaics/PVSystem"])
    pv_power = orig_pv_system_values[:max_power_output]
    pv_num_panels = orig_pv_system_values[:hescore_num_panels]

    if pv_power.nil?
      pv_power = pv_num_panels * 300.0 # FIXME: Hard-coded
    end

    HPXML.add_pv_system(hpxml: hpxml,
                        id: "PVSystem",
                        module_type: "standard", # From https://docs.google.com/spreadsheets/d/1YeoVOwu9DU-50fxtT_KRh_BJLlchF7nls85Ebe9fDkI
                        array_type: "fixed roof mount", # FIXME: Verify. HEScore was using "fixed open rack"??
                        array_azimuth: orientation_to_azimuth(orig_pv_system_values[:array_orientation]),
                        array_tilt: @roof_angle,
                        max_power_output: pv_power,
                        inverter_efficiency: 0.96, # From https://docs.google.com/spreadsheets/d/1YeoVOwu9DU-50fxtT_KRh_BJLlchF7nls85Ebe9fDkI
                        system_losses_fraction: 0.14) # FIXME: Needs to be calculated
  end

  def self.set_appliances_clothes_washer(hpxml)
    HPXML.add_clothes_washer(hpxml: hpxml,
                             id: "ClothesWasher")
    # Uses ERI Reference Home for performance
  end

  def self.set_appliances_clothes_dryer(hpxml)
    HPXML.add_clothes_dryer(hpxml: hpxml,
                            id: "ClothesDryer",
                            fuel_type: "electricity")
    # Uses ERI Reference Home for performance
  end

  def self.set_appliances_dishwasher(hpxml)
    HPXML.add_dishwasher(hpxml: hpxml,
                         id: "Dishwasher")
    # Uses ERI Reference Home for performance
  end

  def self.set_appliances_refrigerator(hpxml)
    HPXML.add_refrigerator(hpxml: hpxml,
                           id: "Refrigerator")
    # Uses ERI Reference Home for performance
  end

  def self.set_appliances_cooking_range_oven(hpxml)
    HPXML.add_cooking_range(hpxml: hpxml,
                            id: "CookingRange",
                            fuel_type: "electricity")

    HPXML.add_oven(hpxml: hpxml,
                   id: "Oven")
    # Uses ERI Reference Home for performance
  end

  def self.set_lighting(orig_details, hpxml)
    HPXML.add_lighting(hpxml: hpxml)
    # Uses ERI Reference Home
  end

  def self.set_ceiling_fans(orig_details, hpxml)
    # No ceiling fans
  end

  def self.set_misc_plug_loads(hpxml)
    HPXML.add_plug_load(hpxml: hpxml,
                        id: "PlugLoadOther",
                        plug_load_type: "other")
    # Uses ERI Reference Home for performance
  end

  def self.set_misc_television(hpxml)
    HPXML.add_plug_load(hpxml: hpxml,
                        id: "PlugLoadTV",
                        plug_load_type: "TV other")
    # Uses ERI Reference Home for performance
  end
end

def get_default_furnace_afue(year, fuel)
  # Furnace AFUE by year/fuel
  # FIXME: Verify
  # TODO: Pull out methods and make available for ERI use case
  # ANSI/RESNET/ICC 301 - Table 4.4.2(3) Default Values for Mechanical System Efficiency (Age-based)
  ending_years = [1959, 1969, 1974, 1983, 1987, 1991, 2005, 9999]
  default_afues = { "electricity" => [0.98, 0.98, 0.98, 0.98, 0.98, 0.98, 0.98, 0.98],
                    "natural gas" => [0.72, 0.72, 0.72, 0.72, 0.72, 0.76, 0.78, 0.78],
                    "propane" => [0.72, 0.72, 0.72, 0.72, 0.72, 0.76, 0.78, 0.78],
                    "fuel oil" => [0.60, 0.65, 0.72, 0.75, 0.80, 0.80, 0.80, 0.80] }[fuel]
  ending_years.zip(default_afues).each do |ending_year, default_afue|
    next if year > ending_year

    return default_afue
  end
  fail "Could not get default furnace AFUE for year '#{year}' and fuel '#{fuel}'"
end

def get_default_boiler_afue(year, fuel)
  # Boiler AFUE by year/fuel
  # FIXME: Verify
  # TODO: Pull out methods and make available for ERI use case
  # ANSI/RESNET/ICC 301 - Table 4.4.2(3) Default Values for Mechanical System Efficiency (Age-based)
  ending_years = [1959, 1969, 1974, 1983, 1987, 1991, 2005, 9999]
  default_afues = { "electricity" => [0.98, 0.98, 0.98, 0.98, 0.98, 0.98, 0.98, 0.98],
                    "natural gas" => [0.60, 0.60, 0.65, 0.65, 0.70, 0.77, 0.80, 0.80],
                    "propane" => [0.60, 0.60, 0.65, 0.65, 0.70, 0.77, 0.80, 0.80],
                    "fuel oil" => [0.60, 0.65, 0.72, 0.75, 0.80, 0.80, 0.80, 0.80] }[fuel]
  ending_years.zip(default_afues).each do |ending_year, default_afue|
    next if year > ending_year

    return default_afue
  end
  fail "Could not get default boiler AFUE for year '#{year}' and fuel '#{fuel}'"
end

def get_default_central_ac_seer(year)
  # Central Air Conditioner SEER by year
  # FIXME: Verify
  # TODO: Pull out methods and make available for ERI use case
  # ANSI/RESNET/ICC 301 - Table 4.4.2(3) Default Values for Mechanical System Efficiency (Age-based)
  ending_years = [1959, 1969, 1974, 1983, 1987, 1991, 2005, 9999]
  default_seers = [9.0, 9.0, 9.0, 9.0, 9.0, 9.40, 10.0, 13.0]
  ending_years.zip(default_seers).each do |ending_year, default_seer|
    next if year > ending_year

    return default_seer
  end
  fail "Could not get default central air conditioner SEER for year '#{year}'"
end

def get_default_room_ac_eer(year)
  # Room Air Conditioner EER by year
  # FIXME: Verify
  # TODO: Pull out methods and make available for ERI use case
  # ANSI/RESNET/ICC 301 - Table 4.4.2(3) Default Values for Mechanical System Efficiency (Age-based)
  ending_years = [1959, 1969, 1974, 1983, 1987, 1991, 2005, 9999]
  default_eers = [8.0, 8.0, 8.0, 8.0, 8.0, 8.10, 8.5, 8.5]
  ending_years.zip(default_eers).each do |ending_year, default_eer|
    next if year > ending_year

    return default_eer
  end
  fail "Could not get default room air conditioner EER for year '#{year}'"
end

def get_default_ashp_seer_hspf(year)
  # Air Source Heat Pump SEER/HSPF by year
  # FIXME: Verify
  # TODO: Pull out methods and make available for ERI use case
  # ANSI/RESNET/ICC 301 - Table 4.4.2(3) Default Values for Mechanical System Efficiency (Age-based)
  ending_years = [1959, 1969, 1974, 1983, 1987, 1991, 2005, 9999]
  default_seers = [9.0, 9.0, 9.0, 9.0, 9.0, 9.40, 10.0, 13.0]
  default_hspfs = [6.5, 6.5, 6.5, 6.5, 6.5, 6.80, 6.80, 7.7]
  ending_years.zip(default_seers, default_hspfs).each do |ending_year, default_seer, default_hspf|
    next if year > ending_year

    return default_seer, default_hspf
  end
  fail "Could not get default air source heat pump SEER/HSPF for year '#{year}'"
end

def get_default_gshp_eer_cop(year)
  # Ground Source Heat Pump EER/COP by year
  # FIXME: Verify
  # TODO: Pull out methods and make available for ERI use case
  # ANSI/RESNET/ICC 301 - Table 4.4.2(3) Default Values for Mechanical System Efficiency (Age-based)
  ending_years = [1959, 1969, 1974, 1983, 1987, 1991, 2005, 9999]
  default_eers = [8.00, 8.00, 8.00, 11.00, 11.00, 12.00, 14.0, 13.4]
  default_cops = [2.30, 2.30, 2.30, 2.50, 2.60, 2.70, 3.00, 3.1]
  ending_years.zip(default_eers, default_cops).each do |ending_year, default_eer, default_cop|
    next if year > ending_year

    return default_eer, default_cop
  end
  fail "Could not get default ground source heat pump EER/COP for year '#{year}'"
end

def get_default_water_heater_ef(year, fuel)
  # Water Heater Energy Factor by year/fuel
  # FIXME: Verify
  # TODO: Pull out methods and make available for ERI use case
  # ANSI/RESNET/ICC 301 - Table 4.4.2(3) Default Values for Mechanical System Efficiency (Age-based)
  ending_years = [1959, 1969, 1974, 1983, 1987, 1991, 2005, 9999]
  default_efs = { "electricity" => [0.86, 0.86, 0.86, 0.86, 0.86, 0.87, 0.88, 0.92],
                  "natural gas" => [0.50, 0.50, 0.50, 0.50, 0.55, 0.56, 0.56, 0.59],
                  "propane" => [0.50, 0.50, 0.50, 0.50, 0.55, 0.56, 0.56, 0.59],
                  "fuel oil" => [0.47, 0.47, 0.47, 0.48, 0.49, 0.54, 0.56, 0.51] }[fuel]
  ending_years.zip(default_efs).each do |ending_year, default_ef|
    next if year > ending_year

    return default_ef
  end
  fail "Could not get default water heater EF for year '#{year}' and fuel '#{fuel}'"
end

def get_default_water_heater_volume(fuel)
  # Water Heater Tank Volume by fuel
  # FIXME: Verify
  # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/water-heater-energy-consumption/user-inputs-to-the-water-heater-model
  val = { "electricity" => 50,
          "natural gas" => 40,
          "propane" => 40,
          "fuel oil" => 32 }[fuel]
  return val if not val.nil?

  fail "Could not get default water heater volume for fuel '#{fuel}'"
end

def get_default_water_heater_re(fuel)
  # Water Heater Recovery Efficiency by fuel
  # FIXME: Verify
  # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/water-heater-energy-consumption/user-inputs-to-the-water-heater-model
  val = { "electricity" => 0.98,
          "natural gas" => 0.76,
          "propane" => 0.76,
          "fuel oil" => 0.76 }[fuel]
  return val if not val.nil?

  fail "Could not get default water heater RE for fuel '#{fuel}'"
end

def get_default_water_heater_capacity(fuel)
  # Water Heater Rated Input Capacity by fuel
  # FIXME: Verify
  # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/water-heater-energy-consumption/user-inputs-to-the-water-heater-model
  val = { "electricity" => UnitConversions.convert(4.5, "kwh", "btu"),
          "natural gas" => 38000,
          "propane" => 38000,
          "fuel oil" => UnitConversions.convert(0.65, "gal", "btu", Constants.FuelTypeOil) }[fuel]
  return val if not val.nil?

  fail "Could not get default water heater capacity for fuel '#{fuel}'"
end

def get_wood_stud_wall_assembly_r(r_cavity, r_cont, siding, ove)
  # Walls Wood Stud Assembly R-value
  # FIXME: Verify
  # FIXME: Does this include air films?
  # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/building-envelope/wall-construction-types
  sidings = ["wood siding", "stucco", "vinyl siding", "aluminum siding", "brick veneer"]
  siding_index = sidings.index(siding)
  if r_cont == 0 and not ove
    val = { 0 => [4.6, 3.2, 3.8, 3.7, 4.7],                                # ewwf00wo, ewwf00st, ewwf00vi, ewwf00al, ewwf00br
            3 => [7.0, 5.8, 6.3, 6.2, 7.1],                                # ewwf03wo, ewwf03st, ewwf03vi, ewwf03al, ewwf03br
            7 => [9.7, 8.5, 9.0, 8.8, 9.8],                                # ewwf07wo, ewwf07st, ewwf07vi, ewwf07al, ewwf07br
            11 => [11.5, 10.2, 10.8, 10.6, 11.6],                          # ewwf11wo, ewwf11st, ewwf11vi, ewwf11al, ewwf11br
            13 => [12.5, 11.1, 11.6, 11.5, 12.5],                          # ewwf13wo, ewwf13st, ewwf13vi, ewwf13al, ewwf13br
            15 => [13.3, 11.9, 12.5, 12.3, 13.3],                          # ewwf15wo, ewwf15st, ewwf15vi, ewwf15al, ewwf15br
            19 => [16.9, 15.4, 16.1, 15.9, 16.9],                          # ewwf19wo, ewwf19st, ewwf19vi, ewwf19al, ewwf19br
            21 => [17.5, 16.1, 16.9, 16.7, 17.9] }[r_cavity][siding_index] # ewwf21wo, ewwf21st, ewwf21vi, ewwf21al, ewwf21br
  elsif r_cont == 5 and not ove
    val = { 11 => [16.7, 15.4, 15.9, 15.9, 16.9],                          # ewps11wo, ewps11st, ewps11vi, ewps11al, ewps11br
            13 => [17.9, 16.4, 16.9, 16.9, 17.9],                          # ewps13wo, ewps13st, ewps13vi, ewps13al, ewps13br
            15 => [18.5, 17.2, 17.9, 17.9, 18.9],                          # ewps15wo, ewps15st, ewps15vi, ewps15al, ewps15br
            19 => [22.2, 20.8, 21.3, 21.3, 22.2],                          # ewps19wo, ewps19st, ewps19vi, ewps19al, ewps19br
            21 => [22.7, 21.7, 22.2, 22.2, 23.3] }[r_cavity][siding_index] # ewps21wo, ewps21st, ewps21vi, ewps21al, ewps21br
  elsif r_cont == 0 and ove
    val = { 19 => [19.2, 17.9, 18.5, 18.2, 19.2],                          # ewov19wo, ewov19st, ewov19vi, ewov19al, ewov19br
            21 => [20.4, 18.9, 19.6, 19.6, 20.4],                          # ewov21wo, ewov21st, ewov21vi, ewov21al, ewov21br
            27 => [25.6, 24.4, 25.0, 24.4, 25.6],                          # ewov27wo, ewov27st, ewov27vi, ewov27al, ewov27br
            33 => [30.3, 29.4, 29.4, 29.4, 30.3],                          # ewov33wo, ewov33st, ewov33vi, ewov33al, ewov33br
            38 => [34.5, 33.3, 34.5, 34.5, 34.5] }[r_cavity][siding_index] # ewov38wo, ewov38st, ewov38vi, ewov38al, ewov38br
  elsif r_cont == 5 and ove
    val = { 19 => [24.4, 23.3, 23.8, 23.3, 24.4],                          # ewop19wo, ewop19st, ewop19vi, ewop19al, ewop19br
            21 => [25.6, 24.4, 25.0, 25.0, 25.6] }[r_cavity][siding_index] # ewop21wo, ewop21st, ewop21vi, ewop21al, ewop21br
  end
  return val if not val.nil?

  fail "Could not get default wood stud wall assembly R-value for R-cavity '#{r_cavity}' and R-cont '#{r_cont}' and siding '#{siding}' and ove '#{ove}'"
end

def get_structural_block_wall_assembly_r(r_cont)
  # Walls Structural Block Assembly R-value
  # FIXME: Verify
  # FIXME: Does this include air films?
  # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/building-envelope/wall-construction-types
  val = { 0 => 2.9,            # ewbr00nn
          5 => 7.9,            # ewbr05nn
          10 => 12.8 }[r_cont] # ewbr10nn
  return val if not val.nil?

  fail "Could not get default structural block wall assembly R-value for R-cavity '#{r_cont}'"
end

def get_concrete_block_wall_assembly_r(r_cavity, siding)
  # Walls Concrete Block Assembly R-value
  # FIXME: Verify
  # FIXME: Does this include air films?
  # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/building-envelope/wall-construction-types
  sidings = ["stucco", "brick veneer", nil]
  siding_index = sidings.index(siding)
  val = { 0 => [4.1, 5.6, 4.0],                           # ewcb00st, ewcb00br, ewcb00nn
          3 => [5.7, 7.2, 5.6],                           # ewcb03st, ewcb03br, ewcb03nn
          6 => [8.5, 10.0, 8.3] }[r_cavity][siding_index] # ewcb06st, ewcb06br, ewcb06nn
  return val if not val.nil?

  fail "Could not get default concrete block wall assembly R-value for R-cavity '#{r_cavity}' and siding '#{siding}'"
end

def get_straw_bale_wall_assembly_r(siding)
  # Walls Straw Bale Assembly R-value
  # FIXME: Verify
  # FIXME: Does this include air films?
  # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/building-envelope/wall-construction-types
  return 58.8 if siding == "stucco" # ewsb00st

  fail "Could not get default straw bale assembly R-value for siding '#{siding}'"
end

def get_roof_assembly_r(r_cavity, r_cont, material, has_radiant_barrier)
  # Roof Assembly R-value
  # FIXME: Verify
  # FIXME: Does this include air films?
  # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/building-envelope/roof-construction-types
  materials = ["asphalt or fiberglass shingles",
               "wood shingles or shakes",
               "slate or tile shingles",
               "concrete",
               "plastic/rubber/synthetic sheeting"]
  material_index = materials.index(material)
  if r_cont == 0 and not has_radiant_barrier
    val = { 0 => [3.3, 4.0, 3.4, 3.4, 3.7],                                 # rfwf00co, rfwf00wo, rfwf00rc, rfwf00lc, rfwf00tg
            11 => [13.5, 14.3, 13.7, 13.5, 13.9],                           # rfwf11co, rfwf11wo, rfwf11rc, rfwf11lc, rfwf11tg
            13 => [14.9, 15.6, 15.2, 14.9, 15.4],                           # rfwf13co, rfwf13wo, rfwf13rc, rfwf13lc, rfwf13tg
            15 => [16.4, 16.9, 16.4, 16.4, 16.7],                           # rfwf15co, rfwf15wo, rfwf15rc, rfwf15lc, rfwf15tg
            19 => [20.0, 20.8, 20.4, 20.4, 20.4],                           # rfwf19co, rfwf19wo, rfwf19rc, rfwf19lc, rfwf19tg
            21 => [21.7, 22.2, 21.7, 21.3, 21.7],                           # rfwf21co, rfwf21wo, rfwf21rc, rfwf21lc, rfwf21tg
            27 => [nil, 27.8, 27.0, 27.0, 27.0] }[r_cavity][material_index] # rfwf27co, rfwf27wo, rfwf27rc, rfwf27lc, rfwf27tg
  elsif r_cont == 0 and has_radiant_barrier
    val = { 0 => [5.6, 6.3, 5.7, 5.6, 6.0] }[r_cavity][material_index]      # rfrb00co, rfrb00wo, rfrb00rc, rfrb00lc, rfrb00tg
  elsif r_cont == 5 and not has_radiant_barrier
    val = { 0 => [8.3, 9.0, 8.4, 8.3, 8.7],                                 # rfps00co, rfps00wo, rfps00rc, rfps00lc, rfps00tg
            11 => [18.5, 19.2, 18.5, 18.5, 18.9],                           # rfps11co, rfps11wo, rfps11rc, rfps11lc, rfps11tg
            13 => [20.0, 20.8, 20.0, 20.0, 20.4],                           # rfps13co, rfps13wo, rfps13rc, rfps13lc, rfps13tg
            15 => [21.3, 22.2, 21.3, 21.3, 21.7],                           # rfps15co, rfps15wo, rfps15rc, rfps15lc, rfps15tg
            19 => [nil, 25.6, 25.6, 25.0, 25.6],                            # rfps19co, rfps19wo, rfps19rc, rfps19lc, rfps19tg
            21 => [nil, 27.0, 27.0, 26.3, 27.0] }[r_cavity][material_index] # rfps21co, rfps21wo, rfps21rc, rfps21lc, rfps21tg
  end
  return val if not val.nil?

  fail "Could not get default roof assembly R-value for R-cavity '#{r_cavity}' and R-cont '#{r_cont}' and material '#{material}' and radiant barrier '#{has_radiant_barrier}'"
end

def get_ceiling_assembly_r(r_cavity)
  # Ceiling Assembly R-value
  # FIXME: Verify
  # FIXME: Does this include air films?
  # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/building-envelope/ceiling-construction-types
  val = { 0 => 2.2,              # ecwf00
          3 => 5.0,              # ecwf03
          6 => 7.6,              # ecwf06
          9 => 10.0,             # ecwf09
          11 => 10.9,            # ecwf11
          19 => 19.2,            # ecwf19
          21 => 21.3,            # ecwf21
          25 => 25.6,            # ecwf25
          30 => 30.3,            # ecwf30
          38 => 38.5,            # ecwf38
          44 => 43.5,            # ecwf44
          49 => 50.0,            # ecwf49
          60 => 58.8 }[r_cavity] # ecwf60
  return val if not val.nil?

  fail "Could not get default ceiling assembly R-value for R-cavity '#{r_cavity}'"
end

def get_floor_assembly_r(r_cavity)
  # Floor Assembly R-value
  # FIXME: Verify
  # FIXME: Does this include air films?
  # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/building-envelope/floor-construction-types
  val = { 0 => 5.9,              # efwf00ca
          11 => 15.6,            # efwf11ca
          13 => 17.2,            # efwf13ca
          15 => 18.5,            # efwf15ca
          19 => 22.2,            # efwf19ca
          21 => 23.8,            # efwf21ca
          25 => 27.0,            # efwf25ca
          30 => 31.3,            # efwf30ca
          38 => 37.0 }[r_cavity] # efwf38ca
  return val if not val.nil?

  fail "Could not get default floor assembly R-value for R-cavity '#{r_cavity}'"
end

def get_window_ufactor_shgc(frame_type, glass_layers, glass_type, gas_fill)
  # Window U-factor/SHGC
  # FIXME: Verify
  # https://docs.google.com/spreadsheets/d/1joG39BeiRj1mV0Lge91P_dkL-0-94lSEY5tJzGvpc2A/edit#gid=909262753
  key = [frame_type, glass_layers, glass_type, gas_fill]
  vals = { ["Aluminum", "single-pane", nil, nil] => [1.27, 0.75],                               # scna
           ["Wood", "single-pane", nil, nil] => [0.89, 0.64],                                   # scnw
           ["Aluminum", "single-pane", "tinted/reflective", nil] => [1.27, 0.64],               # stna
           ["Wood", "single-pane", "tinted/reflective", nil] => [0.89, 0.54],                   # stnw
           ["Aluminum", "double-pane", nil, "air"] => [0.81, 0.67],                             # dcaa
           ["AluminumThermalBreak", "double-pane", nil, "air"] => [0.60, 0.67],                 # dcab
           ["Wood", "double-pane", nil, "air"] => [0.51, 0.56],                                 # dcaw
           ["Aluminum", "double-pane", "tinted/reflective", "air"] => [0.81, 0.55],             # dtaa
           ["AluminumThermalBreak", "double-pane", "tinted/reflective", "air"] => [0.60, 0.55], # dtab
           ["Wood", "double-pane", "tinted/reflective", "air"] => [0.51, 0.46],                 # dtaw
           ["Wood", "double-pane", "low-e", "air"] => [0.42, 0.52],                             # dpeaw
           ["AluminumThermalBreak", "double-pane", "low-e", "argon"] => [0.47, 0.62],           # dpeaab
           ["Wood", "double-pane", "low-e", "argon"] => [0.39, 0.52],                           # dpeaaw
           ["Aluminum", "double-pane", "reflective", "air"] => [0.67, 0.37],                    # dseaa
           ["AluminumThermalBreak", "double-pane", "reflective", "air"] => [0.47, 0.37],        # dseab
           ["Wood", "double-pane", "reflective", "air"] => [0.39, 0.31],                        # dseaw
           ["Wood", "double-pane", "reflective", "argon"] => [0.36, 0.31],                      # dseaaw
           ["Wood", "triple-pane", "low-e", "argon"] => [0.27, 0.31] }[key]                     # thmabw
  return vals if not vals.nil?

  fail "Could not get default window U/SHGC for frame type '#{frame_type}' and glass layers '#{glass_layers}' and glass type '#{glass_type}' and gas fill '#{gas_fill}'"
end

def get_skylight_ufactor_shgc(frame_type, glass_layers, glass_type, gas_fill)
  # Skylight U-factor/SHGC
  # FIXME: Verify
  # https://docs.google.com/spreadsheets/d/1joG39BeiRj1mV0Lge91P_dkL-0-94lSEY5tJzGvpc2A/edit#gid=909262753
  key = [frame_type, glass_layers, glass_type, gas_fill]
  vals = { ["Aluminum", "single-pane", nil, nil] => [1.98, 0.75],                               # scna
           ["Wood", "single-pane", nil, nil] => [1.47, 0.64],                                   # scnw
           ["Aluminum", "single-pane", "tinted/reflective", nil] => [1.98, 0.64],               # stna
           ["Wood", "single-pane", "tinted/reflective", nil] => [1.47, 0.54],                   # stnw
           ["Aluminum", "double-pane", nil, "air"] => [1.30, 0.67],                             # dcaa
           ["AluminumThermalBreak", "double-pane", nil, "air"] => [1.10, 0.67],                 # dcab
           ["Wood", "double-pane", nil, "air"] => [0.84, 0.56],                                 # dcaw
           ["Aluminum", "double-pane", "tinted/reflective", "air"] => [1.30, 0.55],             # dtaa
           ["AluminumThermalBreak", "double-pane", "tinted/reflective", "air"] => [1.10, 0.55], # dtab
           ["Wood", "double-pane", "tinted/reflective", "air"] => [0.84, 0.46],                 # dtaw
           ["Wood", "double-pane", "low-e", "air"] => [0.74, 0.52],                             # dpeaw
           ["AluminumThermalBreak", "double-pane", "low-e", "argon"] => [0.95, 0.62],           # dpeaab
           ["Wood", "double-pane", "low-e", "argon"] => [0.68, 0.52],                           # dpeaaw
           ["Aluminum", "double-pane", "reflective", "air"] => [1.17, 0.37],                    # dseaa
           ["AluminumThermalBreak", "double-pane", "reflective", "air"] => [0.98, 0.37],        # dseab
           ["Wood", "double-pane", "reflective", "air"] => [0.71, 0.31],                        # dseaw
           ["Wood", "double-pane", "reflective", "argon"] => [0.65, 0.31],                      # dseaaw
           ["Wood", "triple-pane", "low-e", "argon"] => [0.47, 0.31] }[key]                     # thmabw
  return vals if not vals.nil?

  fail "Could not get default skylight U/SHGC for frame type '#{frame_type}' and glass layers '#{glass_layers}' and glass type '#{glass_type}' and gas fill '#{gas_fill}'"
end

def get_roof_solar_absorptance(roof_color)
  # FIXME: Verify
  # https://docs.google.com/spreadsheets/d/1joG39BeiRj1mV0Lge91P_dkL-0-94lSEY5tJzGvpc2A/edit#gid=1325866208
  val = { "reflective" => 0.40,
          "white" => 0.50,
          "light" => 0.65,
          "medium" => 0.75,
          "medium dark" => 0.85,
          "dark" => 0.95 }[roof_color]
  return val if not val.nil?

  fail "Could not get roof absorptance for color '#{roof_color}'"
end

def calc_ach50(ncfl_ag, cfa, height, cvolume, desc, year_built, iecc_cz, orig_details)
  # FIXME: Verify
  # http://hes-documentation.lbl.gov/calculation-methodology/calculation-of-energy-consumption/heating-and-cooling-calculation/infiltration/infiltration
  c_floor_area = -2.08E-03
  c_height = 6.38E-02

  c_vintage = nil
  if year_built < 1960
    c_vintage = -2.50E-01
  elsif year_built <= 1969
    c_vintage = -4.33E-01
  elsif year_built <= 1979
    c_vintage = -4.52E-01
  elsif year_built <= 1989
    c_vintage = -6.54E-01
  elsif year_built <= 1999
    c_vintage = -9.15E-01
  elsif year_built >= 2000
    c_vintage = -1.06E+00
  end
  fail "Could not look up infiltration c_vintage." if c_vintage.nil?

  # FIXME: A-7 vs AK-7?
  c_iecc = nil
  if iecc_cz == "1A" or iecc_cz == "2A"
    c_iecc = 4.73E-01
  elsif iecc_cz == "3A"
    c_iecc = 2.53E-01
  elsif iecc_cz == "4A"
    c_iecc = 3.26E-01
  elsif iecc_cz == "5A"
    c_iecc = 1.12E-01
  elsif iecc_cz == "6A" or iecc_cz == "7"
    c_iecc = 0.0
  elsif iecc_cz == "2B" or iecc_cz == "3B"
    c_iecc = -3.76E-02
  elsif iecc_cz == "4B" or iecc_cz == "5B"
    c_iecc = -8.77E-03
  elsif iecc_cz == "6B"
    c_iecc = 1.94E-02
  elsif iecc_cz == "3C"
    c_iecc = 4.83E-02
  elsif iecc_cz == "4C"
    c_iecc = 2.58E-01
  elsif iecc_cz == "8"
    c_iecc = -5.12E-01
  end
  fail "Could not look up infiltration c_iecc." if c_iecc.nil?

  # FIXME: How to handle multiple foundations?
  c_foundation = nil
  foundation_type = "slab" # FIXME: Connect to input
  if foundation_type == "slab"
    c_foundation = -0.036992
  elsif foundation_type == "conditioned basement" or foundation_type == "unvented crawlspace"
    c_foundation = 0.108713
  elsif foundation_type == "unconditioned basement" or foundation_type == "vented crawlspace"
    c_foundation = 0.180352
  end
  fail "Could not look up infiltration c_foundation." if c_foundation.nil?

  # FIXME: How to handle no ducts or multiple duct locations?
  # FIXME: How to handle ducts in unvented crawlspace?
  c_duct = nil
  duct_location = "conditioned space" # FIXME: Connect to input
  if duct_location == "conditioned space"
    c_duct = -0.12381
  elsif duct_location == "unconditioned attic" or duct_location == "unconditioned basement"
    c_duct = 0.07126
  elsif duct_location == "vented crawlspace"
    c_duct = 0.18072
  end
  fail "Could not look up infiltration c_duct." if c_duct.nil?

  c_sealed = nil
  if desc == "tight"
    c_sealed = -0.384 # FIXME: Hard-coded. Not included in Table 1
  elsif desc == "average"
    c_sealed = 0.0
  end
  fail "Could not look up infiltration c_sealed." if c_sealed.nil?

  floor_area_m2 = UnitConversions.convert(cfa, "ft^2", "m^2")
  height_m = UnitConversions.convert(height, "ft", "m")

  # Normalized leakage
  nl = Math.exp(floor_area_m2 * c_floor_area +
                height_m * c_height +
                c_sealed + c_vintage + c_iecc + c_foundation + c_duct)

  # Specific Leakage Area
  sla = nl / 1000.0 * ncfl_ag**0.3

  ach50 = Airflow.get_infiltration_ACH50_from_SLA(sla, 0.65, cfa, cvolume)

  return ach50
end

def orientation_to_azimuth(orientation)
  return { "northeast" => 45,
           "east" => 90,
           "southeast" => 135,
           "south" => 180,
           "southwest" => 225,
           "west" => 270,
           "northwest" => 315,
           "north" => 0 }[orientation]
end

def reverse_orientation(orientation)
  # Converts, e.g., "northwest" to "southeast"
  reverse = orientation
  if reverse.include? "north"
    reverse = reverse.gsub("north", "south")
  else
    reverse = reverse.gsub("south", "north")
  end
  if reverse.include? "east"
    reverse = reverse.gsub("east", "west")
  else
    reverse = reverse.gsub("west", "east")
  end
  return reverse
end

def sanitize_azimuth(azimuth)
  # Ensure 0 <= orientation < 360
  while azimuth < 0
    azimtuh += 360
  end
  while azimuth >= 360
    azimuth -= 360
  end
  return azimuth
end

def get_attached(attached_name, orig_details, search_in)
  orig_details.elements.each(search_in) do |other_element|
    next if attached_name != HPXML.get_id(other_element)

    return other_element
  end
  fail "Could not find attached element for '#{attached_name}'."
end
