# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

require 'openstudio'
require 'rexml/document'
require 'rexml/xpath'
require 'pathname'
require 'csv'
require_relative "resources/EPvalidator"
require_relative "resources/airflow"
require_relative "resources/constants"
require_relative "resources/constructions"
require_relative "resources/geometry"
require_relative "resources/hotwater_appliances"
require_relative "resources/hvac"
require_relative "resources/hvac_sizing"
require_relative "resources/lighting"
require_relative "resources/location"
require_relative "resources/misc_loads"
require_relative "resources/pv"
require_relative "resources/unit_conversions"
require_relative "resources/util"
require_relative "resources/waterheater"
require_relative "resources/xmlhelper"
require_relative "resources/hpxml"

# start the measure
class HPXMLTranslator < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    return "HPXML Translator"
  end

  # human readable description
  def description
    return "Translates HPXML file to OpenStudio Model"
  end

  # human readable description of modeling approach
  def modeler_description
    return ""
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    arg = OpenStudio::Measure::OSArgument.makeStringArgument("hpxml_path", true)
    arg.setDisplayName("HPXML File Path")
    arg.setDescription("Absolute (or relative) path of the HPXML file.")
    args << arg

    arg = OpenStudio::Measure::OSArgument.makeStringArgument("weather_dir", true)
    arg.setDisplayName("Weather Directory")
    arg.setDescription("Absolute path of the weather directory.")
    args << arg

    arg = OpenStudio::Measure::OSArgument.makeStringArgument("schemas_dir", false)
    arg.setDisplayName("HPXML Schemas Directory")
    arg.setDescription("Absolute path of the hpxml schemas directory.")
    args << arg

    arg = OpenStudio::Measure::OSArgument.makeStringArgument("epw_output_path", false)
    arg.setDisplayName("EPW Output File Path")
    arg.setDescription("Absolute (or relative) path of the output EPW file.")
    args << arg

    arg = OpenStudio::Measure::OSArgument.makeStringArgument("osm_output_path", false)
    arg.setDisplayName("OSM Output File Path")
    arg.setDescription("Absolute (or relative) path of the output OSM file.")
    args << arg

    arg = OpenStudio::Measure::OSArgument.makeBoolArgument("skip_validation", true)
    arg.setDisplayName("Skip HPXML validation")
    arg.setDescription("If true, only checks for and reports HPXML validation issues if an error occurs during processing. Used for faster runtime.")
    arg.setDefaultValue(false)
    args << arg

    arg = OpenStudio::Measure::OSArgument.makeStringArgument("map_tsv_dir", false)
    arg.setDisplayName("Map TSV Directory")
    arg.setDescription("Creates TSV files in the specified directory that map some HPXML object names to EnergyPlus object names. Required for ERI calculation.")
    args << arg

    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # Check for correct versions of OS
    os_version = "2.8.0"
    if OpenStudio.openStudioVersion != os_version
      fail "OpenStudio version #{os_version} is required."
    end

    # assign the user inputs to variables
    hpxml_path = runner.getStringArgumentValue("hpxml_path", user_arguments)
    weather_dir = runner.getStringArgumentValue("weather_dir", user_arguments)
    schemas_dir = runner.getOptionalStringArgumentValue("schemas_dir", user_arguments)
    epw_output_path = runner.getOptionalStringArgumentValue("epw_output_path", user_arguments)
    osm_output_path = runner.getOptionalStringArgumentValue("osm_output_path", user_arguments)
    skip_validation = runner.getBoolArgumentValue("skip_validation", user_arguments)
    map_tsv_dir = runner.getOptionalStringArgumentValue("map_tsv_dir", user_arguments)

    unless (Pathname.new hpxml_path).absolute?
      hpxml_path = File.expand_path(File.join(File.dirname(__FILE__), hpxml_path))
    end
    unless File.exists?(hpxml_path) and hpxml_path.downcase.end_with? ".xml"
      runner.registerError("'#{hpxml_path}' does not exist or is not an .xml file.")
      return false
    end

    hpxml_doc = XMLHelper.parse_file(hpxml_path)

    # Check for invalid HPXML file up front?
    if not skip_validation
      if not validate_hpxml(runner, hpxml_path, hpxml_doc, schemas_dir)
        return false
      end
    end

    begin
      # Weather file
      climate_and_risk_zones_values = HPXML.get_climate_and_risk_zones_values(climate_and_risk_zones: hpxml_doc.elements["/HPXML/Building/BuildingDetails/ClimateandRiskZones"])
      weather_wmo = climate_and_risk_zones_values[:weather_station_wmo]
      epw_path = nil
      CSV.foreach(File.join(weather_dir, "data.csv"), headers: true) do |row|
        next if row["wmo"] != weather_wmo

        epw_path = File.join(weather_dir, row["filename"])
        if not File.exists?(epw_path)
          runner.registerError("'#{epw_path}' could not be found.")
          return false
        end
        cache_path = epw_path.gsub('.epw', '.cache')
        if not File.exists?(cache_path)
          runner.registerError("'#{cache_path}' could not be found.")
          return false
        end
        break
      end
      if epw_path.nil?
        runner.registerError("Weather station WMO '#{weather_wmo}' could not be found in weather/data.csv.")
        return false
      end
      if epw_output_path.is_initialized
        FileUtils.cp(epw_path, epw_output_path.get)
      end

      # Apply Location to obtain weather data
      success, weather = Location.apply(model, runner, epw_path, "NA", "NA")
      return false if not success

      # Create OpenStudio model
      if not OSModel.create(hpxml_doc, runner, model, weather, map_tsv_dir)
        runner.registerError("Unsuccessful creation of OpenStudio model.")
        return false
      end
    rescue Exception => e
      if skip_validation
        # Something went wrong, check for invalid HPXML file now. This was previously
        # skipped to reduce runtime (see https://github.com/NREL/OpenStudio-ERI/issues/47).
        validate_hpxml(runner, hpxml_path, hpxml_doc, schemas_dir)
      end

      # Report exception
      runner.registerError("#{e.message}\n#{e.backtrace.join("\n")}")
      return false
    end

    if osm_output_path.is_initialized
      File.write(osm_output_path.get, model.to_s)
      runner.registerInfo("Wrote file: #{osm_output_path.get}")
    end

    return true
  end

  def validate_hpxml(runner, hpxml_path, hpxml_doc, schemas_dir)
    is_valid = true

    if schemas_dir.is_initialized
      schemas_dir = schemas_dir.get
      unless (Pathname.new schemas_dir).absolute?
        schemas_dir = File.expand_path(File.join(File.dirname(__FILE__), schemas_dir))
      end
      unless Dir.exists?(schemas_dir)
        runner.registerError("'#{schemas_dir}' does not exist.")
        return false
      end
    else
      schemas_dir = nil
    end

    # Validate input HPXML against schema
    if not schemas_dir.nil?
      XMLHelper.validate(hpxml_doc.to_s, File.join(schemas_dir, "HPXML.xsd"), runner).each do |error|
        runner.registerError("#{hpxml_path}: #{error.to_s}")
        is_valid = false
      end
      runner.registerInfo("#{hpxml_path}: Validated against HPXML schema.")
    else
      runner.registerWarning("#{hpxml_path}: No schema dir provided, no HPXML validation performed.")
    end

    # Validate input HPXML against EnergyPlus Use Case
    errors = EnergyPlusValidator.run_validator(hpxml_doc)
    errors.each do |error|
      runner.registerError("#{hpxml_path}: #{error}")
      is_valid = false
    end
    runner.registerInfo("#{hpxml_path}: Validated against HPXML EnergyPlus Use Case.")

    return is_valid
  end
end

class OSModel
  def self.create(hpxml_doc, runner, model, weather, map_tsv_dir)
    # Simulation parameters
    success = add_simulation_params(runner, model)
    return false if not success

    hpxml = hpxml_doc.elements["HPXML"]
    hpxml_values = HPXML.get_hpxml_values(hpxml: hpxml)
    building = hpxml_doc.elements["/HPXML/Building"]

    @eri_version = hpxml_values[:eri_calculation_version]
    fail "Could not find ERI Version" if @eri_version.nil?

    # Global variables
    building_construction_values = HPXML.get_building_construction_values(building_construction: building.elements["BuildingDetails/BuildingSummary/BuildingConstruction"])
    @cfa = building_construction_values[:conditioned_floor_area]
    @cfa_ag = @cfa
    building.elements.each("BuildingDetails/Enclosure/Foundations/Foundation[FoundationType/Basement[Conditioned='true']]") do |foundation|
      foundation.elements.each("Slab") do |fnd_slab|
        slab_values = HPXML.get_foundation_slab_values(slab: fnd_slab)
        @cfa_ag -= slab_values[:area]
      end
    end
    @gfa = 0 # garage floor area
    building.elements.each("BuildingDetails/Enclosure/Garages/Garage/Slabs/Slab") do |garage_slab|
      slab_values = HPXML.get_garage_slab_values(slab: garage_slab)
      @gfa += slab_values[:area]
    end
    @cvolume = building_construction_values[:conditioned_building_volume]
    @ncfl = building_construction_values[:number_of_conditioned_floors]
    @ncfl_ag = building_construction_values[:number_of_conditioned_floors_above_grade]
    @nbeds = building_construction_values[:number_of_bedrooms]
    @nbaths = 3.0 # TODO: Arbitrary, but update
    foundation_values = HPXML.get_foundation_values(foundation: building.elements["BuildingDetails/Enclosure/Foundations/Foundation[FoundationType/Basement[Conditioned='false']]"])
    @has_uncond_bsmnt = (not foundation_values.nil?)
    @subsurface_areas_by_surface = calc_subsurface_areas_by_surface(building)
    @default_azimuth = get_default_azimuth(building)
    @min_neighbor_distance = get_min_neighbor_distance(building)

    loop_hvacs = {} # mapping between HPXML HVAC systems and model air/plant loops
    zone_hvacs = {} # mapping between HPXML HVAC systems and model zonal HVACs
    loop_dhws = {}  # mapping between HPXML Water Heating systems and plant loops

    use_only_ideal_air = false
    if not building_construction_values[:use_only_ideal_air_system].nil?
      use_only_ideal_air = building_construction_values[:use_only_ideal_air_system]
    end

    # Geometry/Envelope

    spaces = {}
    success = add_geometry_envelope(runner, model, building, weather, spaces)
    return false if not success

    # Bedrooms, Occupants

    success = add_num_occupants(model, building, runner)
    return false if not success

    # Hot Water

    success = add_hot_water_and_appliances(runner, model, building, weather, spaces, loop_dhws)
    return false if not success

    # HVAC

    @total_frac_remaining_heat_load_served = 1.0
    @total_frac_remaining_cool_load_served = 1.0

    control_zone = get_space_of_type(spaces, Constants.SpaceTypeLiving).thermalZone.get
    slave_zones = get_spaces_of_type(spaces, [Constants.SpaceTypeConditionedBasement]).map { |z| z.thermalZone.get }.compact
    @control_slave_zones_hash = { control_zone => slave_zones }

    # FIXME: Temporarily adding ideal air systems first to work around E+ bug
    # https://github.com/NREL/EnergyPlus/issues/7264
    success = add_residual_hvac(runner, model, building, use_only_ideal_air)
    return false if not success

    success = add_cooling_system(runner, model, building, loop_hvacs, zone_hvacs, use_only_ideal_air)
    return false if not success

    success = add_heating_system(runner, model, building, loop_hvacs, zone_hvacs, use_only_ideal_air)
    return false if not success

    success = add_heat_pump(runner, model, building, weather, loop_hvacs, zone_hvacs, use_only_ideal_air)
    return false if not success

    success = add_setpoints(runner, model, building, weather, spaces)
    return false if not success

    success = add_ceiling_fans(runner, model, building, spaces)
    return false if not success

    # Plug Loads & Lighting

    success = add_mels(runner, model, building, spaces)
    return false if not success

    success = add_lighting(runner, model, building, weather, spaces)
    return false if not success

    # Other

    success = add_airflow(runner, model, building, loop_hvacs, spaces)
    return false if not success

    success = add_hvac_sizing(runner, model, weather)
    return false if not success

    success = add_fuel_heating_eae(runner, model, building, loop_hvacs, zone_hvacs)
    return false if not success

    success = add_photovoltaics(runner, model, building)
    return false if not success

    success = add_building_output_variables(runner, model, loop_hvacs, zone_hvacs, loop_dhws, map_tsv_dir)
    return false if not success

    return true
  end

  private

  def self.add_simulation_params(runner, model)
    sim = model.getSimulationControl
    sim.setRunSimulationforSizingPeriods(false)

    tstep = model.getTimestep
    tstep.setNumberOfTimestepsPerHour(1)

    shad = model.getShadowCalculation
    shad.setCalculationFrequency(20)
    shad.setMaximumFiguresInShadowOverlapCalculations(200)

    outsurf = model.getOutsideSurfaceConvectionAlgorithm
    outsurf.setAlgorithm('DOE-2')

    insurf = model.getInsideSurfaceConvectionAlgorithm
    insurf.setAlgorithm('TARP')

    zonecap = model.getZoneCapacitanceMultiplierResearchSpecial
    zonecap.setHumidityCapacityMultiplier(15)

    convlim = model.getConvergenceLimits
    convlim.setMinimumSystemTimestep(0)

    return true
  end

  def self.add_geometry_envelope(runner, model, building, weather, spaces)
    heating_season, cooling_season = HVAC.calc_heating_and_cooling_seasons(model, weather, runner)
    return false if heating_season.nil? or cooling_season.nil?

    success = add_foundations(runner, model, building, spaces)
    return false if not success

    success = add_garages(runner, model, building, spaces)
    return false if not success

    success = add_walls(runner, model, building, spaces)
    return false if not success

    success = add_rim_joists(runner, model, building, spaces)
    return false if not success

    success = add_windows(runner, model, building, spaces, weather, cooling_season)
    return false if not success

    success = add_doors(runner, model, building, spaces)
    return false if not success

    success = add_skylights(runner, model, building, spaces, weather, cooling_season)
    return false if not success

    success = add_attics(runner, model, building, spaces)
    return false if not success

    success = add_conditioned_floor_area(runner, model, building, spaces)
    return false if not success

    success = add_thermal_mass(runner, model, building)
    return false if not success

    success = check_for_errors(runner, model)
    return false if not success

    success = set_zone_volumes(runner, model, building)
    return false if not success

    success = explode_surfaces(runner, model, building)
    return false if not success

    return true
  end

  def self.set_zone_volumes(runner, model, building)
    # TODO: Use HPXML values not Model values
    thermal_zones = model.getThermalZones

    # Init
    living_volume = @cvolume
    zones_updated = 0

    # Basements, crawl, garage
    thermal_zones.each do |thermal_zone|
      if Geometry.is_conditioned_basement(thermal_zone) or Geometry.is_unconditioned_basement(thermal_zone) or Geometry.is_crawl(thermal_zone) or Geometry.is_garage(thermal_zone)
        zones_updated += 1

        zone_floor_area = 0.0
        thermal_zone.spaces.each do |space|
          space.surfaces.each do |surface|
            if surface.surfaceType.downcase == "floor"
              zone_floor_area += UnitConversions.convert(surface.grossArea, "m^2", "ft^2")
            end
          end
        end

        zone_volume = Geometry.get_height_of_spaces(thermal_zone.spaces) * zone_floor_area
        if zone_volume <= 0
          fail "Calculated volume for #{thermal_zone.name} zone (#{zone_volume}) is not greater than zero."
        end

        thermal_zone.setVolume(UnitConversions.convert(zone_volume, "ft^3", "m^3"))

        if Geometry.is_conditioned_basement(thermal_zone)
          living_volume = @cvolume - zone_volume
        end

      end
    end

    # Conditioned living
    thermal_zones.each do |thermal_zone|
      if Geometry.is_living(thermal_zone)
        zones_updated += 1

        if living_volume <= 0
          fail "Calculated volume for living zone (#{living_volume}) is not greater than zero."
        end

        thermal_zone.setVolume(UnitConversions.convert(living_volume, "ft^3", "m^3"))
      end
    end

    # Attic
    thermal_zones.each do |thermal_zone|
      if Geometry.is_unconditioned_attic(thermal_zone)
        zones_updated += 1

        zone_surfaces = []
        zone_floor_area = 0.0
        thermal_zone.spaces.each do |space|
          space.surfaces.each do |surface|
            zone_surfaces << surface
            if surface.surfaceType.downcase == "floor"
              zone_floor_area += UnitConversions.convert(surface.grossArea, "m^2", "ft^2")
            end
          end
        end

        # Assume square hip roof for volume calculations; energy results are very insensitive to actual volume
        zone_length = zone_floor_area**0.5
        zone_height = Math.tan(UnitConversions.convert(Geometry.get_roof_pitch(zone_surfaces), "deg", "rad")) * zone_length / 2.0
        zone_volume = [zone_floor_area * zone_height / 3.0, 0.01].max
        thermal_zone.setVolume(UnitConversions.convert(zone_volume, "ft^3", "m^3"))
      end
    end

    if zones_updated != thermal_zones.size
      fail "Unhandled volume calculations for thermal zones."
    end

    return true
  end

  def self.explode_surfaces(runner, model, building)
    # Re-position surfaces so as to not shade each other and to make it easier to visualize the building.
    # FUTURE: Might be able to use the new self-shading options in E+ 8.9 ShadowCalculation object?

    gap_distance = UnitConversions.convert(10.0, "ft", "m") # distance between surfaces of the same azimuth
    rad90 = UnitConversions.convert(90, "deg", "rad")

    # Determine surfaces to shift and distance with which to explode surfaces horizontally outward
    surfaces = []
    azimuth_lengths = {}
    model.getSurfaces.sort.each do |surface|
      next unless ["wall", "roofceiling"].include? surface.surfaceType.downcase
      next unless ["outdoors", "foundation"].include? surface.outsideBoundaryCondition.downcase
      next if surface.additionalProperties.getFeatureAsDouble("Tilt").get <= 0 # skip flat roofs

      surfaces << surface
      azimuth = surface.additionalProperties.getFeatureAsInteger("Azimuth").get
      if azimuth_lengths[azimuth].nil?
        azimuth_lengths[azimuth] = 0.0
      end
      azimuth_lengths[azimuth] += surface.additionalProperties.getFeatureAsDouble("Length").get + gap_distance
    end
    max_azimuth_length = azimuth_lengths.values.max

    # Using the max length for a given azimuth, calculate the apothem (radius of the incircle) of a regular
    # n-sided polygon to create the smallest polygon possible without self-shading. The number of polygon
    # sides is defined by the minimum difference between two azimuths.
    min_azimuth_diff = 360
    azimuths_sorted = azimuth_lengths.keys.sort
    azimuths_sorted.each_with_index do |az, idx|
      diff1 = (az - azimuths_sorted[(idx + 1) % azimuths_sorted.size]).abs
      diff2 = 360.0 - diff1 # opposite direction
      if diff1 < min_azimuth_diff
        min_azimuth_diff = diff1
      end
      if diff2 < min_azimuth_diff
        min_azimuth_diff = diff2
      end
    end
    nsides = (360.0 / min_azimuth_diff).ceil
    nsides = 4 if nsides < 4 # assume rectangle at the minimum
    explode_distance = max_azimuth_length / (2.0 * Math.tan(UnitConversions.convert(180.0 / nsides, "deg", "rad")))

    success = add_neighbors(runner, model, building, max_azimuth_length)
    return false if not success

    # Initial distance of shifts at 90-degrees to horizontal outward
    azimuth_side_shifts = {}
    azimuth_lengths.keys.each do |azimuth|
      azimuth_side_shifts[azimuth] = max_azimuth_length / 2.0
    end

    # Explode neighbors
    model.getShadingSurfaceGroups.each do |shading_surface_group|
      next if shading_surface_group.name.to_s != Constants.ObjectNameNeighbors

      shading_surface_group.shadingSurfaces.each do |shading_surface|
        azimuth = shading_surface.additionalProperties.getFeatureAsInteger("Azimuth").get
        azimuth_rad = UnitConversions.convert(azimuth, "deg", "rad")
        distance = shading_surface.additionalProperties.getFeatureAsDouble("Distance").get

        unless azimuth_lengths.keys.include? azimuth
          runner.registerError("A neighbor building has an azimuth (#{azimuth}) not equal to the azimuth of any wall.")
          return false
        end

        # Push out horizontally
        distance += explode_distance
        transformation = get_surface_transformation(distance, Math::sin(azimuth_rad), Math::cos(azimuth_rad), 0)

        shading_surface.setVertices(transformation * shading_surface.vertices)
      end
    end

    # Explode walls, windows, doors, roofs, and skylights
    surfaces_moved = []

    surfaces.sort.each do |surface|
      next if surface.additionalProperties.getFeatureAsDouble("Tilt").get <= 0 # skip flat roofs

      if surface.adjacentSurface.is_initialized
        next if surfaces_moved.include? surface.adjacentSurface.get
      end

      azimuth = surface.additionalProperties.getFeatureAsInteger("Azimuth").get
      azimuth_rad = UnitConversions.convert(azimuth, "deg", "rad")

      # Push out horizontally
      distance = explode_distance

      if surface.surfaceType.downcase == "roofceiling"
        # Ensure pitched surfaces are positioned outward justified with walls, etc.
        roof_tilt = surface.additionalProperties.getFeatureAsDouble("Tilt").get
        roof_width = surface.additionalProperties.getFeatureAsDouble("Width").get
        distance -= 0.5 * Math.cos(Math.atan(roof_tilt)) * roof_width
      end
      transformation = get_surface_transformation(distance, Math::sin(azimuth_rad), Math::cos(azimuth_rad), 0)

      surface.setVertices(transformation * surface.vertices)
      if surface.adjacentSurface.is_initialized
        surface.adjacentSurface.get.setVertices(transformation * surface.adjacentSurface.get.vertices)
      end
      surface.subSurfaces.each do |subsurface|
        subsurface.setVertices(transformation * subsurface.vertices)
        next unless subsurface.subSurfaceType.downcase == "fixedwindow"

        subsurface.shadingSurfaceGroups.each do |overhang_group|
          overhang_group.shadingSurfaces.each do |overhang|
            overhang.setVertices(transformation * overhang.vertices)
          end
        end
      end

      # Shift at 90-degrees to previous transformation
      azimuth_side_shifts[azimuth] -= surface.additionalProperties.getFeatureAsDouble("Length").get / 2.0
      transformation_shift = get_surface_transformation(azimuth_side_shifts[azimuth], Math::sin(azimuth_rad + rad90), Math::cos(azimuth_rad + rad90), 0)

      surface.setVertices(transformation_shift * surface.vertices)
      if surface.adjacentSurface.is_initialized
        surface.adjacentSurface.get.setVertices(transformation_shift * surface.adjacentSurface.get.vertices)
      end
      surface.subSurfaces.each do |subsurface|
        subsurface.setVertices(transformation_shift * subsurface.vertices)
        next unless subsurface.subSurfaceType.downcase == "fixedwindow"

        subsurface.shadingSurfaceGroups.each do |overhang_group|
          overhang_group.shadingSurfaces.each do |overhang|
            overhang.setVertices(transformation_shift * overhang.vertices)
          end
        end
      end

      azimuth_side_shifts[azimuth] -= (surface.additionalProperties.getFeatureAsDouble("Length").get / 2.0 + gap_distance)

      surfaces_moved << surface
    end

    return true
  end

  def self.check_for_errors(runner, model)
    # Check every thermal zone has:
    # 1. At least one floor surface
    # 2. At least one roofceiling surface
    # 3. At least one surface adjacent to outside/ground
    model.getThermalZones.each do |zone|
      n_floors = 0
      n_roofceilings = 0
      n_exteriors = 0
      zone.spaces.each do |space|
        space.surfaces.each do |surface|
          if ["outdoors", "foundation"].include? surface.outsideBoundaryCondition.downcase
            n_exteriors += 1
          end
          if surface.surfaceType.downcase == "floor"
            n_floors += 1
          elsif surface.surfaceType.downcase == "roofceiling"
            n_roofceilings += 1
          end
        end
      end

      if n_floors == 0
        runner.registerError("Thermal zone '#{zone.name}' must have at least one floor surface.")
      end
      if n_roofceilings == 0
        runner.registerError("Thermal zone '#{zone.name}' must have at least one roof/ceiling surface.")
      end
      if n_exteriors == 0
        runner.registerError("Thermal zone '#{zone.name}' must have at least one surface adjacent to outside/ground.")
      end
      if n_floors == 0 or n_roofceilings == 0 or n_exteriors == 0
        return false
      end
    end

    return true
  end

  def self.create_space_and_zone(model, spaces, space_type)
    if not spaces.keys.include? space_type
      thermal_zone = OpenStudio::Model::ThermalZone.new(model)
      thermal_zone.setName(space_type)

      space = OpenStudio::Model::Space.new(model)
      space.setName(space_type)

      st = OpenStudio::Model::SpaceType.new(model)
      st.setStandardsSpaceType(space_type)
      space.setSpaceType(st)

      space.setThermalZone(thermal_zone)
      spaces[space_type] = space
    end
  end

  def self.get_surface_transformation(offset, x, y, z)
    x = UnitConversions.convert(x, "ft", "m")
    y = UnitConversions.convert(y, "ft", "m")
    z = UnitConversions.convert(z, "ft", "m")

    m = OpenStudio::Matrix.new(4, 4, 0)
    m[0, 0] = 1
    m[1, 1] = 1
    m[2, 2] = 1
    m[3, 3] = 1
    m[0, 3] = x * offset
    m[1, 3] = y * offset
    m[2, 3] = z.abs * offset

    return OpenStudio::Transformation.new(m)
  end

  def self.add_floor_polygon(x, y, z)
    x = UnitConversions.convert(x, "ft", "m")
    y = UnitConversions.convert(y, "ft", "m")
    z = UnitConversions.convert(z, "ft", "m")

    vertices = OpenStudio::Point3dVector.new
    vertices << OpenStudio::Point3d.new(0 - x / 2, 0 - y / 2, z)
    vertices << OpenStudio::Point3d.new(0 - x / 2, y / 2, z)
    vertices << OpenStudio::Point3d.new(x / 2, y / 2, z)
    vertices << OpenStudio::Point3d.new(x / 2, 0 - y / 2, z)

    return vertices
  end

  def self.add_wall_polygon(x, y, z, azimuth = 0, offsets = [0] * 4)
    x = UnitConversions.convert(x, "ft", "m")
    y = UnitConversions.convert(y, "ft", "m")
    z = UnitConversions.convert(z, "ft", "m")

    vertices = OpenStudio::Point3dVector.new
    vertices << OpenStudio::Point3d.new(0 - (x / 2) - offsets[1], 0, z - offsets[0])
    vertices << OpenStudio::Point3d.new(0 - (x / 2) - offsets[1], 0, z + y + offsets[2])
    vertices << OpenStudio::Point3d.new(x - (x / 2) + offsets[3], 0, z + y + offsets[2])
    vertices << OpenStudio::Point3d.new(x - (x / 2) + offsets[3], 0, z - offsets[0])

    # Rotate about the z axis
    azimuth_rad = UnitConversions.convert(azimuth, "deg", "rad")
    m = OpenStudio::Matrix.new(4, 4, 0)
    m[0, 0] = Math::cos(-azimuth_rad)
    m[1, 1] = Math::cos(-azimuth_rad)
    m[0, 1] = -Math::sin(-azimuth_rad)
    m[1, 0] = Math::sin(-azimuth_rad)
    m[2, 2] = 1
    m[3, 3] = 1
    transformation = OpenStudio::Transformation.new(m)

    return transformation * vertices
  end

  def self.add_roof_polygon(x, y, z, azimuth = 0, tilt = 0.5)
    x = UnitConversions.convert(x, "ft", "m")
    y = UnitConversions.convert(y, "ft", "m")
    z = UnitConversions.convert(z, "ft", "m")

    vertices = OpenStudio::Point3dVector.new
    vertices << OpenStudio::Point3d.new(x / 2, -y / 2, 0)
    vertices << OpenStudio::Point3d.new(x / 2, y / 2, 0)
    vertices << OpenStudio::Point3d.new(-x / 2, y / 2, 0)
    vertices << OpenStudio::Point3d.new(-x / 2, -y / 2, 0)

    # Rotate about the x axis
    m = OpenStudio::Matrix.new(4, 4, 0)
    m[0, 0] = 1
    m[1, 1] = Math::cos(Math::atan(tilt))
    m[1, 2] = -Math::sin(Math::atan(tilt))
    m[2, 1] = Math::sin(Math::atan(tilt))
    m[2, 2] = Math::cos(Math::atan(tilt))
    m[3, 3] = 1
    transformation = OpenStudio::Transformation.new(m)
    vertices = transformation * vertices

    # Rotate about the z axis
    azimuth_rad = UnitConversions.convert(azimuth, "deg", "rad")
    rad180 = UnitConversions.convert(180, "deg", "rad")
    m = OpenStudio::Matrix.new(4, 4, 0)
    m[0, 0] = Math::cos(rad180 - azimuth_rad)
    m[1, 1] = Math::cos(rad180 - azimuth_rad)
    m[0, 1] = -Math::sin(rad180 - azimuth_rad)
    m[1, 0] = Math::sin(rad180 - azimuth_rad)
    m[2, 2] = 1
    m[3, 3] = 1
    transformation = OpenStudio::Transformation.new(m)
    vertices = transformation * vertices

    # Shift up by z
    new_vertices = OpenStudio::Point3dVector.new
    vertices.each do |vertex|
      new_vertices << OpenStudio::Point3d.new(vertex.x, vertex.y, vertex.z + z)
    end

    return new_vertices
  end

  def self.add_ceiling_polygon(x, y, z)
    return OpenStudio::reverse(add_floor_polygon(x, y, z))
  end

  def self.net_surface_area(gross_area, surface_id, surface_type)
    net_area = gross_area
    if @subsurface_areas_by_surface.keys.include? surface_id
      net_area -= @subsurface_areas_by_surface[surface_id]
    end

    if net_area <= 0
      fail "Calculated a negative net surface area for #{surface_type} '#{surface_id}'."
    end

    return net_area
  end

  def self.add_num_occupants(model, building, runner)
    building_occupancy_values = HPXML.get_building_occupancy_values(building_occupancy: building.elements["BuildingDetails/BuildingSummary/BuildingOccupancy"])

    # Occupants
    num_occ = Geometry.get_occupancy_default_num(@nbeds)
    unless building_occupancy_values.nil?
      unless building_occupancy_values[:number_of_residents].nil?
        num_occ = building_occupancy_values[:number_of_residents]
      end
    end
    if num_occ > 0
      occ_gain, hrs_per_day, sens_frac, lat_frac = Geometry.get_occupancy_default_values()
      weekday_sch = "1.00000, 1.00000, 1.00000, 1.00000, 1.00000, 1.00000, 1.00000, 0.88310, 0.40861, 0.24189, 0.24189, 0.24189, 0.24189, 0.24189, 0.24189, 0.24189, 0.29498, 0.55310, 0.89693, 0.89693, 0.89693, 1.00000, 1.00000, 1.00000" # TODO: Normalize schedule based on hrs_per_day
      weekend_sch = weekday_sch
      monthly_sch = "1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0"
      success = Geometry.process_occupants(model, runner, num_occ, occ_gain, sens_frac, lat_frac, weekday_sch, weekend_sch, monthly_sch, @cfa, @nbeds)
      return false if not success
    end

    return true
  end

  def self.calc_subsurface_areas_by_surface(building)
    # Returns a hash with the amount of subsurface (window/skylight/door)
    # area for each surface. Used to convert gross surface area to net surface
    # area for a given surface.
    subsurface_areas = {}

    # Windows
    building.elements.each("BuildingDetails/Enclosure/Windows/Window") do |window|
      window_values = HPXML.get_window_values(window: window)
      wall_id = window_values[:wall_idref]
      subsurface_areas[wall_id] = 0.0 if subsurface_areas[wall_id].nil?
      subsurface_areas[wall_id] += window_values[:area]
    end

    # Skylights
    building.elements.each("BuildingDetails/Enclosure/Skylights/Skylight") do |skylight|
      skylight_values = HPXML.get_skylight_values(skylight: skylight)
      roof_id = skylight_values[:roof_idref]
      subsurface_areas[roof_id] = 0.0 if subsurface_areas[roof_id].nil?
      subsurface_areas[roof_id] += skylight_values[:area]
    end

    # Doors
    building.elements.each("BuildingDetails/Enclosure/Doors/Door") do |door|
      door_values = HPXML.get_door_values(door: door)
      wall_id = door_values[:wall_idref]
      subsurface_areas[wall_id] = 0.0 if subsurface_areas[wall_id].nil?
      subsurface_areas[wall_id] += door_values[:area]
    end

    return subsurface_areas
  end

  def self.get_default_azimuth(building)
    building.elements.each("BuildingDetails/Enclosure//Azimuth") do |azimuth|
      return Integer(azimuth.text)
    end
    return 90
  end

  def self.create_or_get_space(model, spaces, spacetype)
    if spaces[spacetype].nil?
      create_space_and_zone(model, spaces, spacetype)
    end
    return spaces[spacetype]
  end

  def self.add_foundations(runner, model, building, spaces)
    # TODO: Refactor by creating methods for add_foundation_walls(), add_foundation_slabs(), etc.

    building.elements.each("BuildingDetails/Enclosure/Foundations/Foundation") do |foundation|
      foundation_values = HPXML.get_foundation_values(foundation: foundation)

      fnd_id = foundation_values[:id]
      foundation_type = foundation_values[:foundation_type]
      interior_adjacent_to = get_foundation_adjacent_to(foundation_type)

      # Calculate sum of foundation wall lengths
      sum_wall_length = 0.0
      foundation.elements.each("FoundationWall") do |fnd_wall|
        foundation_wall_values = HPXML.get_foundation_wall_values(foundation_wall: fnd_wall)
        next if foundation_wall_values[:adjacent_to] != "ground"

        wall_net_area = net_surface_area(foundation_wall_values[:area], foundation_wall_values[:id], "Wall")
        sum_wall_length += wall_net_area / foundation_wall_values[:height]
      end

      # Obtain the exposed perimeter for each slab
      slabs_perimeter_exposed = {}
      foundation.elements.each("Slab") do |fnd_slab|
        slab_values = HPXML.get_foundation_slab_values(slab: fnd_slab)
        slabs_perimeter_exposed[slab_values[:id]] = slab_values[:exposed_perimeter]
      end

      # Foundation wall surfaces
      foundation_object = {}
      foundation_wall_heights = []
      foundation.elements.each("FoundationWall") do |fnd_wall|
        foundation_wall_values = HPXML.get_foundation_wall_values(foundation_wall: fnd_wall)
        next if foundation_wall_values[:adjacent_to] != "ground"

        wall_id = foundation_wall_values[:id]
        exterior_adjacent_to = foundation_wall_values[:adjacent_to]

        wall_height = foundation_wall_values[:height]
        wall_net_area = net_surface_area(foundation_wall_values[:area], wall_id, "Wall")
        foundation_wall_heights << wall_height
        wall_height_above_grade = wall_height - foundation_wall_values[:depth_below_grade]
        z_origin = -1 * foundation_wall_values[:depth_below_grade]
        wall_length = wall_net_area / wall_height

        wall_azimuth = @default_azimuth # don't split up surface due to the Kiva runtime impact
        if not foundation_wall_values[:azimuth].nil?
          wall_azimuth = foundation_wall_values[:azimuth]
        end

        # Attach a portion of the foundation wall to each slab. This is
        # needed if there are multiple Slab elements defined for the foundation.
        slabs_perimeter_exposed.each do |slab_id, slab_perimeter_exposed|
          # Calculate exposed section of wall based on slab's total exposed perimeter.
          # Apportioned to each foundation wall.
          wall_length = wall_length * slab_perimeter_exposed / sum_wall_length

          surface = OpenStudio::Model::Surface.new(add_wall_polygon(wall_length, wall_height, z_origin,
                                                                    wall_azimuth), model)

          surface.additionalProperties.setFeature("Length", wall_length)
          surface.additionalProperties.setFeature("Azimuth", wall_azimuth)
          surface.additionalProperties.setFeature("Tilt", 90.0)
          surface.setName(wall_id)
          surface.setSurfaceType("Wall")
          set_surface_interior(model, spaces, surface, wall_id, interior_adjacent_to)
          set_surface_exterior(model, spaces, surface, wall_id, exterior_adjacent_to)

          if is_external_thermal_boundary(interior_adjacent_to, exterior_adjacent_to)
            wall_drywall_thick_in = 0.5
          else
            wall_drywall_thick_in = 0.0
          end
          wall_filled_cavity = true
          wall_concrete_thick_in = foundation_wall_values[:thickness]
          wall_cavity_r = 0.0
          wall_cavity_depth_in = 0.0
          wall_install_grade = 1
          wall_framing_factor = 0.0
          wall_assembly_r = foundation_wall_values[:insulation_assembly_r_value]
          if not wall_assembly_r.nil?
            wall_rigid_height = wall_height
            wall_film_r = Material.AirFilmVertical.rvalue
            wall_rigid_r = wall_assembly_r - Material.Concrete(wall_concrete_thick_in).rvalue - Material.GypsumWall(wall_drywall_thick_in).rvalue - wall_film_r
            if wall_rigid_r < 0 # Try without drywall
              wall_drywall_thick_in = 0.0
              wall_rigid_r = wall_assembly_r - Material.Concrete(wall_concrete_thick_in).rvalue - Material.GypsumWall(wall_drywall_thick_in).rvalue - wall_film_r
            end
          else
            wall_rigid_height = foundation_wall_values[:insulation_height]
            wall_rigid_r = foundation_wall_values[:insulation_r_value]
          end

          # TODO: Currently assumes all walls have the same height, insulation height, etc.
          # Refactor so that we create the single Kiva foundation object based on average values.
          success = Constructions.apply_foundation_wall(runner, model, [surface], "FndWallConstruction",
                                                        wall_rigid_height, wall_cavity_r, wall_install_grade,
                                                        wall_cavity_depth_in, wall_filled_cavity, wall_framing_factor,
                                                        wall_rigid_r, wall_drywall_thick_in, wall_concrete_thick_in,
                                                        wall_height, wall_height_above_grade, foundation_object[slab_id])
          return false if not success

          if not wall_assembly_r.nil?
            check_surface_assembly_rvalue(surface, wall_film_r, wall_assembly_r)
          end

          foundation_object[slab_id] = surface.adjacentFoundation.get
        end
      end

      # Foundation slab surfaces
      slab_depth_below_grade = nil
      foundation.elements.each("Slab") do |fnd_slab|
        slab_values = HPXML.get_foundation_slab_values(slab: fnd_slab)

        slab_id = slab_values[:id]

        # Need to ensure surface perimeter >= user-specified exposed perimeter
        # (for Kiva) and surface area == user-specified area.
        slab_exp_perim = slab_values[:exposed_perimeter]
        slab_tot_perim = slab_exp_perim
        if slab_tot_perim**2 - 16.0 * slab_values[:area] <= 0
          # Cannot construct rectangle with this perimeter/area. Some of the
          # perimeter is presumably not exposed, so bump up perimeter value.
          slab_tot_perim = Math.sqrt(16.0 * slab_values[:area])
        end
        sqrt_term = slab_tot_perim**2 - 16.0 * slab_values[:area]
        slab_length = slab_tot_perim / 4.0 + Math.sqrt(sqrt_term) / 4.0
        slab_width = slab_tot_perim / 4.0 - Math.sqrt(sqrt_term) / 4.0

        slab_depth_below_grade = slab_values[:depth_below_grade]
        z_origin = -1 * slab_depth_below_grade

        surface = OpenStudio::Model::Surface.new(add_floor_polygon(slab_length, slab_width, z_origin), model)

        surface.setName(slab_id)
        surface.setSurfaceType("Floor")
        surface.setOutsideBoundaryCondition("Foundation")
        set_surface_interior(model, spaces, surface, slab_id, interior_adjacent_to)
        surface.setSunExposure("NoSun")
        surface.setWindExposure("NoWind")

        slab_concrete_thick_in = slab_values[:thickness]

        slab_perim_r = slab_values[:perimeter_insulation_r_value]
        slab_perim_depth = slab_values[:perimeter_insulation_depth]
        if slab_perim_r == 0 or slab_perim_depth == 0
          slab_perim_r = 0
          slab_perim_depth = 0
        end

        if slab_values[:under_slab_insulation_spans_entire_slab]
          slab_whole_r = slab_values[:under_slab_insulation_r_value]
          slab_under_r = 0
          slab_under_width = 0
        else
          slab_under_r = slab_values[:under_slab_insulation_r_value]
          slab_under_width = slab_values[:under_slab_insulation_width]
          if slab_under_r == 0 or slab_under_width == 0
            slab_under_r = 0
            slab_under_width = 0
          end
          slab_whole_r = 0
        end
        slab_gap_r = slab_under_r

        mat_carpet = nil
        if slab_values[:carpet_fraction] > 0 and slab_values[:carpet_r_value] > 0
          mat_carpet = Material.CoveringBare(slab_values[:carpet_fraction],
                                             slab_values[:carpet_r_value])
        end

        success = Constructions.apply_foundation_slab(runner, model, surface, "SlabConstruction",
                                                      slab_under_r, slab_under_width, slab_gap_r, slab_perim_r,
                                                      slab_perim_depth, slab_whole_r, slab_concrete_thick_in,
                                                      slab_exp_perim, mat_carpet, foundation_object[slab_id])
        return false if not success

        # FIXME: Temporary code for sizing
        surface.additionalProperties.setFeature(Constants.SizingInfoSlabRvalue, 5.0)
      end

      # Foundation ceiling surfaces
      foundation.elements.each("FrameFloor") do |fnd_floor|
        frame_floor_values = HPXML.get_foundation_framefloor_values(floor: fnd_floor)

        floor_id = frame_floor_values[:id]

        exterior_adjacent_to = frame_floor_values[:adjacent_to]

        framefloor_area = frame_floor_values[:area]
        framefloor_width = Math::sqrt(framefloor_area)
        framefloor_length = framefloor_area / framefloor_width

        if foundation_type == "Ambient"
          z_origin = 2.0
        elsif foundation_type.include? "Basement" or foundation_type.include? "Crawlspace"
          avg_foundation_wall_height = foundation_wall_heights.reduce(:+) / foundation_wall_heights.size.to_f
          z_origin = -1 * slab_depth_below_grade + avg_foundation_wall_height
        end

        surface = OpenStudio::Model::Surface.new(add_ceiling_polygon(framefloor_length, framefloor_width, z_origin), model)

        surface.setName(floor_id)
        if interior_adjacent_to == "outside" # pier & beam foundation
          surface.setSurfaceType("Floor")
          set_surface_interior(model, spaces, surface, floor_id, exterior_adjacent_to)
          set_surface_exterior(model, spaces, surface, floor_id, interior_adjacent_to)
        else
          surface.setSurfaceType("RoofCeiling")
          set_surface_interior(model, spaces, surface, floor_id, interior_adjacent_to)
          set_surface_exterior(model, spaces, surface, floor_id, exterior_adjacent_to)
        end
        surface.setSunExposure("NoSun")
        surface.setWindExposure("NoWind")

        floor_film_r = 2.0 * Material.AirFilmFloorReduced.rvalue
        floor_assembly_r = frame_floor_values[:insulation_assembly_r_value]
        constr_sets = [
          WoodStudConstructionSet.new(Material.Stud2x6, 0.10, 10.0, 0.75, 0.0, Material.CoveringBare), # 2x6, 24" o.c. + R10
          WoodStudConstructionSet.new(Material.Stud2x6, 0.10, 0.0, 0.75, 0.0, Material.CoveringBare),  # 2x6, 24" o.c.
          WoodStudConstructionSet.new(Material.Stud2x4, 0.13, 0.0, 0.5, 0.0, Material.CoveringBare),   # 2x4, 16" o.c.
          WoodStudConstructionSet.new(Material.Stud2x4, 0.01, 0.0, 0.0, 0.0, nil),                     # Fallback
        ]
        floor_constr_set, floor_cav_r = pick_wood_stud_construction_set(floor_assembly_r, constr_sets, floor_film_r, "foundation framefloor #{floor_id}")

        mat_floor_covering = nil
        floor_grade = 1

        # Foundation ceiling
        success = Constructions.apply_floor(runner, model, [surface], "FndCeilingConstruction",
                                            floor_cav_r, floor_grade,
                                            floor_constr_set.framing_factor, floor_constr_set.stud.thick_in,
                                            floor_constr_set.osb_thick_in, floor_constr_set.rigid_r,
                                            mat_floor_covering, floor_constr_set.exterior_material)
        return false if not success

        if not floor_assembly_r.nil?
          check_surface_assembly_rvalue(surface, floor_film_r, floor_assembly_r)
        end
      end
    end

    return true
  end

  def self.add_garages(runner, model, building, spaces)
    # TODO: Refactor by creating methods for add_garage_ceilings(), add_garage_walls(), etc.

    building_construction_values = HPXML.get_building_construction_values(building_construction: building.elements["BuildingDetails/BuildingSummary/BuildingConstruction"])

    building.elements.each("BuildingDetails/Enclosure/Garages/Garage") do |garage|
      garage_values = HPXML.get_garage_values(garage: garage)

      interior_adjacent_to = "garage"

      # Garage ceiling surface
      garage.elements.each("Ceilings/Ceiling") do |garage_ceiling|
        ceiling_values = HPXML.get_garage_ceiling_values(ceiling: garage_ceiling)

        ceiling_id = ceiling_values[:id]

        exterior_adjacent_to = ceiling_values[:adjacent_to]

        ceiling_area = ceiling_values[:area]
        ceiling_width = Math::sqrt(ceiling_area)
        ceiling_length = ceiling_area / ceiling_width

        z_origin = 8.0

        surface = OpenStudio::Model::Surface.new(add_ceiling_polygon(ceiling_length, ceiling_width, z_origin), model)

        surface.setName(ceiling_id)
        surface.setSurfaceType("RoofCeiling")
        set_surface_interior(model, spaces, surface, ceiling_id, interior_adjacent_to)
        set_surface_exterior(model, spaces, surface, ceiling_id, exterior_adjacent_to)
        surface.setSunExposure("NoSun")
        surface.setWindExposure("NoWind")

        ceiling_film_r = 2.0 * Material.AirFilmFloorReduced.rvalue
        ceiling_assembly_r = ceiling_values[:insulation_assembly_r_value]
        constr_sets = [
          WoodStudConstructionSet.new(Material.Stud2x6, 0.10, 10.0, 0.75, 0.0, Material.CoveringBare), # 2x6, 24" o.c. + R10
          WoodStudConstructionSet.new(Material.Stud2x6, 0.10, 0.0, 0.75, 0.0, Material.CoveringBare),  # 2x6, 24" o.c.
          WoodStudConstructionSet.new(Material.Stud2x4, 0.13, 0.0, 0.5, 0.0, Material.CoveringBare),   # 2x4, 16" o.c.
          WoodStudConstructionSet.new(Material.Stud2x4, 0.01, 0.0, 0.0, 0.0, nil),                     # Fallback
        ]
        ceiling_constr_set, ceiling_cav_r = pick_wood_stud_construction_set(ceiling_assembly_r, constr_sets, ceiling_film_r, "garage ceiling #{ceiling_id}")

        mat_ceiling_covering = nil
        ceiling_grade = 1

        success = Constructions.apply_floor(runner, model, [surface], "FndCeilingConstruction",
                                            ceiling_cav_r, ceiling_grade,
                                            ceiling_constr_set.framing_factor, ceiling_constr_set.stud.thick_in,
                                            ceiling_constr_set.osb_thick_in, ceiling_constr_set.rigid_r,
                                            mat_ceiling_covering, ceiling_constr_set.exterior_material)
        return false if not success

        if not ceiling_assembly_r.nil?
          check_surface_assembly_rvalue(surface, ceiling_film_r, ceiling_assembly_r)
        end
      end

      # Garage wall surfaces
      garage.elements.each("Walls/Wall") do |garage_wall|
        wall_values = HPXML.get_garage_wall_values(wall: garage_wall)

        interior_adjacent_to = "garage"
        exterior_adjacent_to = wall_values[:adjacent_to]
        wall_id = wall_values[:id]
        wall_net_area = net_surface_area(wall_values[:area], wall_id, "Wall")
        wall_height = 8.0 * building_construction_values[:number_of_conditioned_floors_above_grade]
        wall_length = wall_net_area / wall_height
        z_origin = 0

        wall_azimuth = @default_azimuth
        if not wall_values[:azimuth].nil?
          wall_azimuth = wall_values[:azimuth]
        end

        surface = OpenStudio::Model::Surface.new(add_wall_polygon(wall_length, wall_height, z_origin,
                                                                  wall_azimuth), model)

        surface.additionalProperties.setFeature("Length", wall_length)
        surface.additionalProperties.setFeature("Azimuth", wall_azimuth)
        surface.additionalProperties.setFeature("Tilt", 90.0)
        surface.setName(wall_id)
        surface.setSurfaceType("Wall")
        set_surface_interior(model, spaces, surface, wall_id, interior_adjacent_to)
        set_surface_exterior(model, spaces, surface, wall_id, exterior_adjacent_to)
        if exterior_adjacent_to != "outside"
          surface.setSunExposure("NoSun")
          surface.setWindExposure("NoWind")
        end

        # Apply construction
        # The code below constructs a reasonable wall construction based on the
        # wall type while ensuring the correct assembly R-value.

        if is_external_thermal_boundary(interior_adjacent_to, exterior_adjacent_to)
          drywall_thick_in = 0.5
        else
          drywall_thick_in = 0.0
        end
        if exterior_adjacent_to == "outside"
          film_r = Material.AirFilmVertical.rvalue + Material.AirFilmOutside.rvalue
          mat_ext_finish = Material.ExtFinishWoodLight
        else
          film_r = 2.0 * Material.AirFilmVertical.rvalue
          mat_ext_finish = nil
        end

        apply_wall_construction(runner, model, surface, wall_id, wall_values[:wall_type], wall_values[:insulation_assembly_r_value],
                                drywall_thick_in, film_r, mat_ext_finish, wall_values[:solar_absorptance], wall_values[:emittance])
      end

      # Garage slab surfaces
      garage.elements.each("Slabs/Slab") do |garage_slab|
        slab_values = HPXML.get_garage_slab_values(slab: garage_slab)

        slab_id = slab_values[:id]

        # Need to ensure surface perimeter >= user-specified exposed perimeter
        # (for Kiva) and surface area == user-specified area.
        slab_exp_perim = slab_values[:exposed_perimeter]
        slab_tot_perim = slab_exp_perim
        if slab_tot_perim**2 - 16.0 * slab_values[:area] <= 0
          # Cannot construct rectangle with this perimeter/area. Some of the
          # perimeter is presumably not exposed, so bump up perimeter value.
          slab_tot_perim = Math.sqrt(16.0 * slab_values[:area])
        end
        sqrt_term = slab_tot_perim**2 - 16.0 * slab_values[:area]
        slab_length = slab_tot_perim / 4.0 + Math.sqrt(sqrt_term) / 4.0
        slab_width = slab_tot_perim / 4.0 - Math.sqrt(sqrt_term) / 4.0

        z_origin = 0

        surface = OpenStudio::Model::Surface.new(add_floor_polygon(slab_length, slab_width, z_origin), model)

        surface.setName(slab_id)
        surface.setSurfaceType("Floor")
        surface.setOutsideBoundaryCondition("Foundation")
        set_surface_interior(model, spaces, surface, slab_id, "garage")
        surface.setSunExposure("NoSun")
        surface.setWindExposure("NoWind")

        slab_concrete_thick_in = slab_values[:thickness]

        slab_perim_r = slab_values[:perimeter_insulation_r_value]
        slab_perim_depth = slab_values[:perimeter_insulation_depth]
        if slab_perim_r == 0 or slab_perim_depth == 0
          slab_perim_r = 0
          slab_perim_depth = 0
        end

        if slab_values[:under_slab_insulation_spans_entire_slab]
          slab_whole_r = slab_values[:under_slab_insulation_r_value]
          slab_under_r = 0
          slab_under_width = 0
        else
          slab_under_r = slab_values[:under_slab_insulation_r_value]
          slab_under_width = slab_values[:under_slab_insulation_width]
          if slab_under_r == 0 or slab_under_width == 0
            slab_under_r = 0
            slab_under_width = 0
          end
          slab_whole_r = 0
        end
        slab_gap_r = slab_under_r

        success = Constructions.apply_foundation_slab(runner, model, surface, "GarageSlabConstruction",
                                                      slab_under_r, slab_under_width, slab_gap_r, slab_perim_r,
                                                      slab_perim_depth, slab_whole_r, slab_concrete_thick_in,
                                                      slab_values[:exposed_perimeter], nil, nil)
        return false if not success
      end
    end

    return true
  end

  def self.add_conditioned_floor_area(runner, model, building, spaces)
    # TODO: Use HPXML values not Model values
    building_construction_values = HPXML.get_building_construction_values(building_construction: building.elements["BuildingDetails/BuildingSummary/BuildingConstruction"])
    cfa = building_construction_values[:conditioned_floor_area].round(1)

    # First check if we need to add a conditioned basement ceiling
    foundation_top = get_foundation_top(model)

    model.getThermalZones.each do |zone|
      next if not Geometry.is_conditioned_basement(zone)

      floor_area = 0.0
      ceiling_area = 0.0
      zone.spaces.each do |space|
        space.surfaces.each do |surface|
          if surface.surfaceType.downcase.to_s == "floor"
            floor_area += UnitConversions.convert(surface.grossArea, "m^2", "ft^2").round(2)
          elsif surface.surfaceType.downcase.to_s == "roofceiling"
            ceiling_area += UnitConversions.convert(surface.grossArea, "m^2", "ft^2").round(2)
          end
        end
      end

      addtl_cfa = floor_area - ceiling_area
      if addtl_cfa > 0
        runner.registerWarning("Adding conditioned basement adiabatic ceiling with #{addtl_cfa.to_s} ft^2.")

        conditioned_floor_width = Math::sqrt(addtl_cfa)
        conditioned_floor_length = addtl_cfa / conditioned_floor_width
        z_origin = foundation_top

        surface = OpenStudio::Model::Surface.new(add_ceiling_polygon(-conditioned_floor_width, -conditioned_floor_length, z_origin), model)

        surface.setSunExposure("NoSun")
        surface.setWindExposure("NoWind")
        surface.setName("inferred conditioned basement ceiling")
        surface.setSurfaceType("RoofCeiling")
        surface.setSpace(zone.spaces[0])
        surface.setOutsideBoundaryCondition("Adiabatic")

        # Apply Construction
        success = apply_adiabatic_construction(runner, model, [surface], "floor")
        return false if not success
      end
    end

    # Next check if we need to add floors between conditioned spaces (e.g., 2-story buildings).

    # Calculate cfa already added to model
    model_cfa = 0.0
    model.getSpaces.each do |space|
      next unless Geometry.space_is_conditioned(space)

      space.surfaces.each do |surface|
        next unless surface.surfaceType.downcase.to_s == "floor"

        model_cfa += UnitConversions.convert(surface.grossArea, "m^2", "ft^2").round(2)
      end
    end

    if model_cfa > cfa
      runner.registerError("Sum of conditioned floor surface areas #{model_cfa.to_s} is greater than ConditionedFloorArea specified #{cfa.to_s}.")
      return false
    end

    addtl_cfa = cfa - model_cfa
    return true unless addtl_cfa > 0

    runner.registerWarning("Adding adiabatic conditioned floor with #{addtl_cfa.to_s} ft^2 to preserve building total conditioned floor area.")

    conditioned_floor_width = Math::sqrt(addtl_cfa)
    conditioned_floor_length = addtl_cfa / conditioned_floor_width
    z_origin = foundation_top + 8.0 * (@ncfl_ag - 1)

    surface = OpenStudio::Model::Surface.new(add_floor_polygon(-conditioned_floor_width, -conditioned_floor_length, z_origin), model)

    surface.setSunExposure("NoSun")
    surface.setWindExposure("NoWind")
    surface.setName("inferred conditioned floor")
    surface.setSurfaceType("Floor")
    surface.setSpace(create_or_get_space(model, spaces, Constants.SpaceTypeLiving))
    surface.setOutsideBoundaryCondition("Adiabatic")

    # Apply Construction
    success = apply_adiabatic_construction(runner, model, [surface], "floor")
    return false if not success

    return true
  end

  def self.add_thermal_mass(runner, model, building)
    drywall_thick_in = 0.5
    partition_frac_of_cfa = 1.0
    success = Constructions.apply_partition_walls(runner, model, [],
                                                  "PartitionWallConstruction",
                                                  drywall_thick_in, partition_frac_of_cfa)
    return false if not success

    # FIXME ?
    furniture_frac_of_cfa = 1.0
    mass_lb_per_sqft = 8.0
    density_lb_per_cuft = 40.0
    mat = BaseMaterial.Wood
    success = Constructions.apply_furniture(runner, model, furniture_frac_of_cfa,
                                            mass_lb_per_sqft, density_lb_per_cuft, mat)
    return false if not success

    return true
  end

  def self.add_walls(runner, model, building, spaces)
    foundation_top = get_foundation_top(model)
    building_construction_values = HPXML.get_building_construction_values(building_construction: building.elements["BuildingDetails/BuildingSummary/BuildingConstruction"])

    building.elements.each("BuildingDetails/Enclosure/Walls/Wall") do |wall|
      wall_values = HPXML.get_wall_values(wall: wall)
      interior_adjacent_to = wall_values[:interior_adjacent_to]
      exterior_adjacent_to = wall_values[:exterior_adjacent_to]
      wall_id = wall_values[:id]
      wall_net_area = net_surface_area(wall_values[:area], wall_id, "Wall")
      wall_height = 8.0 * building_construction_values[:number_of_conditioned_floors_above_grade]
      wall_length = wall_net_area / wall_height
      z_origin = foundation_top
      wall_azimuth = @default_azimuth
      if not wall_values[:azimuth].nil?
        wall_azimuth = wall_values[:azimuth]
      end

      surface = OpenStudio::Model::Surface.new(add_wall_polygon(wall_length, wall_height, z_origin,
                                                                wall_azimuth), model)

      surface.additionalProperties.setFeature("Length", wall_length)
      surface.additionalProperties.setFeature("Azimuth", wall_azimuth)
      surface.additionalProperties.setFeature("Tilt", 90.0)
      surface.setName(wall_id)
      surface.setSurfaceType("Wall")
      set_surface_interior(model, spaces, surface, wall_id, interior_adjacent_to)
      set_surface_exterior(model, spaces, surface, wall_id, exterior_adjacent_to)
      if exterior_adjacent_to != "outside"
        surface.setSunExposure("NoSun")
        surface.setWindExposure("NoWind")
      end

      # Apply construction
      # The code below constructs a reasonable wall construction based on the
      # wall type while ensuring the correct assembly R-value.

      if is_external_thermal_boundary(interior_adjacent_to, exterior_adjacent_to)
        drywall_thick_in = 0.5
      else
        drywall_thick_in = 0.0
      end
      if exterior_adjacent_to == "outside"
        film_r = Material.AirFilmVertical.rvalue + Material.AirFilmOutside.rvalue
        mat_ext_finish = Material.ExtFinishWoodLight
      else
        film_r = 2.0 * Material.AirFilmVertical.rvalue
        mat_ext_finish = nil
      end

      apply_wall_construction(runner, model, surface, wall_id, wall_values[:wall_type], wall_values[:insulation_assembly_r_value],
                              drywall_thick_in, film_r, mat_ext_finish, wall_values[:solar_absorptance], wall_values[:emittance])
    end

    return true
  end

  def self.add_neighbors(runner, model, building, wall_length)
    # Get the max z-value of any model surface
    wall_height = -9e99
    model.getSpaces.each do |space|
      z_origin = space.zOrigin
      space.surfaces.each do |surface|
        surface.vertices.each do |vertex|
          surface_z = vertex.z + z_origin
          next if surface_z < wall_height

          wall_height = surface_z
        end
      end
    end
    wall_height = UnitConversions.convert(wall_height, "m", "ft")
    z_origin = 0 # shading surface always starts at grade

    shading_surfaces = []
    building.elements.each("BuildingDetails/BuildingSummary/Site/extension/Neighbors/NeighborBuilding") do |neighbor_building|
      neighbor_building_values = HPXML.get_neighbor_building_values(neighbor_building: neighbor_building)
      azimuth = neighbor_building_values[:azimuth]
      distance = neighbor_building_values[:distance]

      shading_surface = OpenStudio::Model::ShadingSurface.new(add_wall_polygon(wall_length, wall_height, z_origin, azimuth), model)
      shading_surface.additionalProperties.setFeature("Azimuth", azimuth)
      shading_surface.additionalProperties.setFeature("Distance", distance)
      shading_surface.setName("Neighbor azimuth #{azimuth} distance #{distance}")

      shading_surfaces << shading_surface
    end

    unless shading_surfaces.empty?
      shading_surface_group = OpenStudio::Model::ShadingSurfaceGroup.new(model)
      shading_surface_group.setName(Constants.ObjectNameNeighbors)
      shading_surfaces.each do |shading_surface|
        shading_surface.setShadingSurfaceGroup(shading_surface_group)
      end
    end

    return true
  end

  def self.add_rim_joists(runner, model, building, spaces)
    foundation_top = get_foundation_top(model)

    building.elements.each("BuildingDetails/Enclosure/RimJoists/RimJoist") do |rim_joist|
      rim_joist_values = HPXML.get_rim_joist_values(rim_joist: rim_joist)
      interior_adjacent_to = rim_joist_values[:interior_adjacent_to]
      exterior_adjacent_to = rim_joist_values[:exterior_adjacent_to]
      rim_joist_id = rim_joist_values[:id]

      rim_joist_height = 1.0
      rim_joist_length = rim_joist_values[:area] / rim_joist_height
      z_origin = foundation_top
      rim_joist_azimuth = @default_azimuth
      if not rim_joist_values[:azimuth].nil?
        rim_joist_azimuth = rim_joist_values[:azimuth]
      end

      surface = OpenStudio::Model::Surface.new(add_wall_polygon(rim_joist_length, rim_joist_height, z_origin,
                                                                rim_joist_azimuth), model)

      surface.additionalProperties.setFeature("Length", rim_joist_length)
      surface.additionalProperties.setFeature("Azimuth", rim_joist_azimuth)
      surface.additionalProperties.setFeature("Tilt", 90.0)
      surface.setName(rim_joist_id)
      surface.setSurfaceType("Wall")
      set_surface_interior(model, spaces, surface, rim_joist_id, interior_adjacent_to)
      set_surface_exterior(model, spaces, surface, rim_joist_id, exterior_adjacent_to)
      if exterior_adjacent_to != "outside"
        surface.setSunExposure("NoSun")
        surface.setWindExposure("NoWind")
      end

      # Apply construction

      if is_external_thermal_boundary(interior_adjacent_to, exterior_adjacent_to)
        drywall_thick_in = 0.5
      else
        drywall_thick_in = 0.0
      end
      if exterior_adjacent_to == "outside"
        film_r = Material.AirFilmVertical.rvalue + Material.AirFilmOutside.rvalue
        mat_ext_finish = Material.ExtFinishWoodLight
      else
        film_r = 2.0 * Material.AirFilmVertical.rvalue
        mat_ext_finish = nil
      end
      solar_abs = rim_joist_values[:solar_absorptance]
      emitt = rim_joist_values[:emittance]

      assembly_r = rim_joist_values[:insulation_assembly_r_value]

      constr_sets = [
        WoodStudConstructionSet.new(Material.Stud2x(2.0), 0.17, 10.0, 2.0, drywall_thick_in, mat_ext_finish),  # 2x4 + R10
        WoodStudConstructionSet.new(Material.Stud2x(2.0), 0.17, 5.0, 2.0, drywall_thick_in, mat_ext_finish),   # 2x4 + R5
        WoodStudConstructionSet.new(Material.Stud2x(2.0), 0.17, 0.0, 2.0, drywall_thick_in, mat_ext_finish),   # 2x4
        WoodStudConstructionSet.new(Material.Stud2x(2.0), 0.01, 0.0, 0.0, 0.0, nil),                           # Fallback
      ]
      constr_set, cavity_r = pick_wood_stud_construction_set(assembly_r, constr_sets, film_r, "rim joist #{rim_joist_id}")
      install_grade = 1

      success = Constructions.apply_rim_joist(runner, model, [surface], "RimJoistConstruction",
                                              cavity_r, install_grade, constr_set.framing_factor,
                                              constr_set.drywall_thick_in, constr_set.osb_thick_in,
                                              constr_set.rigid_r, constr_set.exterior_material)
      return false if not success

      check_surface_assembly_rvalue(surface, film_r, assembly_r)

      apply_solar_abs_emittance_to_construction(surface, solar_abs, emitt)
    end

    return true
  end

  def self.add_attics(runner, model, building, spaces)
    # TODO: Refactor by creating methods for add_attic_floors(), add_attic_walls(), etc.

    walls_top = get_walls_top(model)

    building.elements.each("BuildingDetails/Enclosure/Attics/Attic") do |attic|
      attic_values = HPXML.get_attic_values(attic: attic)

      interior_adjacent_to = get_attic_adjacent_to(attic_values[:attic_type])

      # Attic floors
      attic.elements.each("Floors/Floor") do |floor|
        attic_floor_values = HPXML.get_attic_floor_values(floor: floor)

        floor_id = attic_floor_values[:id]
        exterior_adjacent_to = attic_floor_values[:adjacent_to]

        floor_area = attic_floor_values[:area]
        floor_width = Math::sqrt(floor_area)
        floor_length = floor_area / floor_width
        z_origin = walls_top

        surface = OpenStudio::Model::Surface.new(add_floor_polygon(floor_length, floor_width, z_origin), model)

        surface.setSunExposure("NoSun")
        surface.setWindExposure("NoWind")
        surface.setName(floor_id)
        surface.setSurfaceType("Floor")
        set_surface_interior(model, spaces, surface, floor_id, interior_adjacent_to)
        set_surface_exterior(model, spaces, surface, floor_id, exterior_adjacent_to)

        # Apply construction

        if is_external_thermal_boundary(interior_adjacent_to, exterior_adjacent_to)
          drywall_thick_in = 0.5
        else
          drywall_thick_in = 0.0
        end
        film_r = 2 * Material.AirFilmFloorAverage.rvalue

        assembly_r = attic_floor_values[:insulation_assembly_r_value]
        constr_sets = [
          WoodStudConstructionSet.new(Material.Stud2x6, 0.11, 0.0, 0.0, drywall_thick_in, nil), # 2x6, 24" o.c.
          WoodStudConstructionSet.new(Material.Stud2x4, 0.24, 0.0, 0.0, drywall_thick_in, nil), # 2x4, 16" o.c.
          WoodStudConstructionSet.new(Material.Stud2x4, 0.01, 0.0, 0.0, 0.0, nil),              # Fallback
        ]

        constr_set, ceiling_r = pick_wood_stud_construction_set(assembly_r, constr_sets, film_r, "attic floor #{floor_id}")
        ceiling_joist_height_in = constr_set.stud.thick_in
        ceiling_ins_thick_in = ceiling_joist_height_in
        ceiling_framing_factor = constr_set.framing_factor
        ceiling_drywall_thick_in = constr_set.drywall_thick_in
        ceiling_install_grade = 1

        success = Constructions.apply_ceiling(runner, model, [surface], "FloorConstruction",
                                              ceiling_r, ceiling_install_grade,
                                              ceiling_ins_thick_in, ceiling_framing_factor,
                                              ceiling_joist_height_in, ceiling_drywall_thick_in)
        return false if not success

        check_surface_assembly_rvalue(surface, film_r, assembly_r)
      end

      # Attic roofs
      attic.elements.each("Roofs/Roof") do |roof|
        attic_roof_values = HPXML.get_attic_roof_values(roof: roof)

        roof_id = attic_roof_values[:id]
        roof_net_area = net_surface_area(attic_roof_values[:area], roof_id, "Roof")
        roof_width = Math::sqrt(roof_net_area)
        roof_length = roof_net_area / roof_width
        if attic_values[:attic_type] != "FlatRoof"
          roof_tilt = attic_roof_values[:pitch] / 12.0
        else
          roof_tilt = 0.0
        end
        z_origin = walls_top + 0.5 * Math.sin(Math.atan(roof_tilt)) * roof_width
        roof_azimuth = @default_azimuth
        if not attic_roof_values[:azimuth].nil?
          roof_azimuth = attic_roof_values[:azimuth]
        end

        surface = OpenStudio::Model::Surface.new(add_roof_polygon(roof_length, roof_width, z_origin,
                                                                  roof_azimuth, roof_tilt), model)

        surface.additionalProperties.setFeature("Length", roof_length)
        surface.additionalProperties.setFeature("Width", roof_width)
        surface.additionalProperties.setFeature("Azimuth", roof_azimuth)
        surface.additionalProperties.setFeature("Tilt", roof_tilt)
        surface.setName(roof_id)
        surface.setSurfaceType("RoofCeiling")
        surface.setOutsideBoundaryCondition("Outdoors")
        set_surface_interior(model, spaces, surface, roof_id, interior_adjacent_to)

        # Apply construction
        if is_external_thermal_boundary(interior_adjacent_to, "outside")
          drywall_thick_in = 0.5
        else
          drywall_thick_in = 0.0
        end
        film_r = Material.AirFilmOutside.rvalue + Material.AirFilmRoof(Geometry.get_roof_pitch([surface])).rvalue
        mat_roofing = Material.RoofingAsphaltShinglesDark
        solar_abs = attic_roof_values[:solar_absorptance]
        emitt = attic_roof_values[:emittance]
        has_radiant_barrier = attic_roof_values[:radiant_barrier]

        assembly_r = attic_roof_values[:insulation_assembly_r_value]
        constr_sets = [
          WoodStudConstructionSet.new(Material.Stud2x(8.0), 0.07, 10.0, 0.75, drywall_thick_in, mat_roofing), # 2x8, 24" o.c. + R10
          WoodStudConstructionSet.new(Material.Stud2x(8.0), 0.07, 5.0, 0.75, drywall_thick_in, mat_roofing),  # 2x8, 24" o.c. + R5
          WoodStudConstructionSet.new(Material.Stud2x(8.0), 0.07, 0.0, 0.75, drywall_thick_in, mat_roofing),  # 2x8, 24" o.c.
          WoodStudConstructionSet.new(Material.Stud2x6, 0.07, 0.0, 0.75, drywall_thick_in, mat_roofing),      # 2x6, 24" o.c.
          WoodStudConstructionSet.new(Material.Stud2x4, 0.07, 0.0, 0.5, drywall_thick_in, mat_roofing),       # 2x4, 16" o.c.
          WoodStudConstructionSet.new(Material.Stud2x4, 0.01, 0.0, 0.0, 0.0, mat_roofing),                    # Fallback
        ]
        constr_set, roof_cavity_r = pick_wood_stud_construction_set(assembly_r, constr_sets, film_r, "attic roof #{roof_id}")

        roof_install_grade = 1

        if drywall_thick_in > 0
          success = Constructions.apply_closed_cavity_roof(runner, model, [surface], "RoofConstruction",
                                                           roof_cavity_r, roof_install_grade,
                                                           constr_set.stud.thick_in,
                                                           true, constr_set.framing_factor,
                                                           constr_set.drywall_thick_in,
                                                           constr_set.osb_thick_in, constr_set.rigid_r,
                                                           constr_set.exterior_material)
        else
          success = Constructions.apply_open_cavity_roof(runner, model, [surface], "RoofConstruction",
                                                         roof_cavity_r, roof_install_grade,
                                                         constr_set.stud.thick_in,
                                                         constr_set.framing_factor,
                                                         constr_set.stud.thick_in,
                                                         constr_set.osb_thick_in, constr_set.rigid_r,
                                                         constr_set.exterior_material, has_radiant_barrier)
          return false if not success
        end

        check_surface_assembly_rvalue(surface, film_r, assembly_r)

        apply_solar_abs_emittance_to_construction(surface, solar_abs, emitt)
      end

      # Attic walls
      attic.elements.each("Walls/Wall") do |wall|
        attic_wall_values = HPXML.get_attic_wall_values(wall: wall)

        exterior_adjacent_to = attic_wall_values[:adjacent_to]
        wall_id = attic_wall_values[:id]
        wall_net_area = net_surface_area(attic_wall_values[:area], wall_id, "Wall")
        wall_height = 8.0
        wall_length = wall_net_area / wall_height
        z_origin = walls_top
        wall_azimuth = @default_azimuth
        if not attic_wall_values[:azimuth].nil?
          wall_azimuth = attic_wall_values[:azimuth]
        end

        surface = OpenStudio::Model::Surface.new(add_wall_polygon(wall_length, wall_height, z_origin,
                                                                  wall_azimuth), model)

        surface.additionalProperties.setFeature("Length", wall_length)
        surface.additionalProperties.setFeature("Azimuth", wall_azimuth)
        surface.additionalProperties.setFeature("Tilt", 90.0)
        surface.setName(wall_id)
        surface.setSurfaceType("Wall")
        set_surface_interior(model, spaces, surface, wall_id, interior_adjacent_to)
        set_surface_exterior(model, spaces, surface, wall_id, exterior_adjacent_to)
        if exterior_adjacent_to != "outside"
          surface.setSunExposure("NoSun")
          surface.setWindExposure("NoWind")
        end

        # Apply construction

        if is_external_thermal_boundary(interior_adjacent_to, exterior_adjacent_to)
          drywall_thick_in = 0.5
        else
          drywall_thick_in = 0.0
        end
        if exterior_adjacent_to == "outside"
          film_r = Material.AirFilmVertical.rvalue + Material.AirFilmOutside.rvalue
          mat_ext_finish = Material.ExtFinishWoodLight
        else
          film_r = 2.0 * Material.AirFilmVertical.rvalue
          mat_ext_finish = nil
        end

        apply_wall_construction(runner, model, surface, wall_id, attic_wall_values[:wall_type], attic_wall_values[:insulation_assembly_r_value],
                                drywall_thick_in, film_r, mat_ext_finish, attic_wall_values[:solar_absorptance], attic_wall_values[:emittance])
      end
    end

    return true
  end

  def self.add_windows(runner, model, building, spaces, weather, cooling_season)
    foundation_top = get_foundation_top(model)

    surfaces = []
    building.elements.each("BuildingDetails/Enclosure/Windows/Window") do |window|
      window_values = HPXML.get_window_values(window: window)

      window_id = window_values[:id]

      window_height = 4.0 # ft, default
      overhang_depth = nil
      if not window.elements["Overhangs"].nil?
        overhang_depth = window_values[:overhangs_depth]
        overhang_distance_to_top = window_values[:overhangs_distance_to_top_of_window]
        overhang_distance_to_bottom = window_values[:overhangs_distance_to_bottom_of_window]
        window_height = overhang_distance_to_bottom - overhang_distance_to_top
      end

      window_area = window_values[:area]
      window_width = window_area / window_height
      z_origin = foundation_top
      window_azimuth = window_values[:azimuth]

      # Create parent surface slightly bigger than window
      surface = OpenStudio::Model::Surface.new(add_wall_polygon(window_width, window_height, z_origin,
                                                                window_azimuth, [0, 0.001, 0.001, 0.001]), model)

      surface.additionalProperties.setFeature("Length", window_width)
      surface.additionalProperties.setFeature("Azimuth", window_azimuth)
      surface.additionalProperties.setFeature("Tilt", 90.0)
      surface.setName("surface #{window_id}")
      surface.setSurfaceType("Wall")
      assign_space_to_subsurface(surface, window_id, window_values[:wall_idref], building, spaces, model, "window")
      surface.setOutsideBoundaryCondition("Outdoors") # cannot be adiabatic because subsurfaces won't be created
      surfaces << surface

      sub_surface = OpenStudio::Model::SubSurface.new(add_wall_polygon(window_width, window_height, z_origin,
                                                                       window_azimuth, [-0.001, 0, 0.001, 0]), model)
      sub_surface.setName(window_id)
      sub_surface.setSurface(surface)
      sub_surface.setSubSurfaceType("FixedWindow")

      if not overhang_depth.nil?
        overhang = sub_surface.addOverhang(UnitConversions.convert(overhang_depth, "ft", "m"), UnitConversions.convert(overhang_distance_to_top, "ft", "m"))
        overhang.get.setName("#{sub_surface.name} - #{Constants.ObjectNameOverhangs}")

        sub_surface.additionalProperties.setFeature(Constants.SizingInfoWindowOverhangDepth, overhang_depth)
        sub_surface.additionalProperties.setFeature(Constants.SizingInfoWindowOverhangOffset, overhang_distance_to_top)
      end

      # Apply construction
      ufactor = window_values[:ufactor]
      shgc = window_values[:shgc]
      default_shade_summer, default_shade_winter = Constructions.get_default_interior_shading_factors()
      cool_shade_mult = default_shade_summer
      if not window_values[:interior_shading_factor_summer].nil?
        cool_shade_mult = window_values[:interior_shading_factor_summer]
      end
      heat_shade_mult = default_shade_winter
      if not window_values[:interior_shading_factor_winter].nil?
        heat_shade_mult = window_values[:interior_shading_factor_winter]
      end
      success = Constructions.apply_window(runner, model, [sub_surface],
                                           "WindowConstruction",
                                           weather, cooling_season, ufactor, shgc,
                                           heat_shade_mult, cool_shade_mult)
      return false if not success
    end

    success = apply_adiabatic_construction(runner, model, surfaces, "wall")
    return false if not success

    return true
  end

  def self.add_skylights(runner, model, building, spaces, weather, cooling_season)
    walls_top = get_walls_top(model)

    surfaces = []
    building.elements.each("BuildingDetails/Enclosure/Skylights/Skylight") do |skylight|
      skylight_values = HPXML.get_skylight_values(skylight: skylight)

      skylight_id = skylight_values[:id]

      # Obtain skylight tilt from attached roof
      skylight_tilt = nil
      building.elements.each("BuildingDetails/Enclosure/Attics/Attic") do |attic|
        attic_values = HPXML.get_attic_values(attic: attic)

        attic.elements.each("Roofs/Roof") do |roof|
          attic_roof_values = HPXML.get_attic_roof_values(roof: roof)
          next unless attic_roof_values[:id] == skylight_values[:roof_idref]

          skylight_tilt = attic_roof_values[:pitch] / 12.0
        end
      end
      if skylight_tilt.nil?
        fail "Attached roof '#{skylight_values[:roof_idref]}' not found for skylight '#{skylight_id}'."
      end

      skylight_area = skylight_values[:area]
      skylight_height = Math::sqrt(skylight_area)
      skylight_width = skylight_area / skylight_height
      z_origin = walls_top + 0.5 * Math.sin(Math.atan(skylight_tilt)) * skylight_height
      skylight_azimuth = skylight_values[:azimuth]

      # Create parent surface slightly bigger than skylight
      surface = OpenStudio::Model::Surface.new(add_roof_polygon(skylight_width + 0.001, skylight_height + 0.001, z_origin,
                                                                skylight_azimuth, skylight_tilt), model)

      surface.additionalProperties.setFeature("Length", skylight_width)
      surface.additionalProperties.setFeature("Width", skylight_height)
      surface.additionalProperties.setFeature("Azimuth", skylight_azimuth)
      surface.additionalProperties.setFeature("Tilt", skylight_tilt)
      surface.setName("surface #{skylight_id}")
      surface.setSurfaceType("RoofCeiling")
      surface.setSpace(create_or_get_space(model, spaces, Constants.SpaceTypeLiving)) # Ensures it is included in Manual J sizing
      surface.setOutsideBoundaryCondition("Outdoors") # cannot be adiabatic because subsurfaces won't be created
      surfaces << surface

      sub_surface = OpenStudio::Model::SubSurface.new(add_roof_polygon(skylight_width, skylight_height, z_origin,
                                                                       skylight_azimuth, skylight_tilt), model)
      sub_surface.setName(skylight_id)
      sub_surface.setSurface(surface)
      sub_surface.setSubSurfaceType("Skylight")

      # Apply construction
      ufactor = skylight_values[:ufactor]
      shgc = skylight_values[:shgc]
      cool_shade_mult = 1.0
      heat_shade_mult = 1.0
      success = Constructions.apply_skylight(runner, model, [sub_surface],
                                             "SkylightConstruction",
                                             weather, cooling_season, ufactor, shgc,
                                             heat_shade_mult, cool_shade_mult)
      return false if not success
    end

    success = apply_adiabatic_construction(runner, model, surfaces, "roof")
    return false if not success

    return true
  end

  def self.add_doors(runner, model, building, spaces)
    foundation_top = get_foundation_top(model)

    surfaces = []
    building.elements.each("BuildingDetails/Enclosure/Doors/Door") do |door|
      door_values = HPXML.get_door_values(door: door)
      door_id = door_values[:id]

      door_area = door_values[:area]
      door_azimuth = door_values[:azimuth]

      door_height = 6.67 # ft
      door_width = door_area / door_height
      z_origin = foundation_top

      # Create parent surface slightly bigger than door
      surface = OpenStudio::Model::Surface.new(add_wall_polygon(door_width, door_height, z_origin,
                                                                door_azimuth, [0, 0.001, 0.001, 0.001]), model)

      surface.additionalProperties.setFeature("Length", door_width)
      surface.additionalProperties.setFeature("Azimuth", door_azimuth)
      surface.additionalProperties.setFeature("Tilt", 90.0)
      surface.setName("surface #{door_id}")
      surface.setSurfaceType("Wall")
      assign_space_to_subsurface(surface, door_id, door_values[:wall_idref], building, spaces, model, "door")
      surface.setOutsideBoundaryCondition("Outdoors") # cannot be adiabatic because subsurfaces won't be created
      surfaces << surface

      sub_surface = OpenStudio::Model::SubSurface.new(add_wall_polygon(door_width, door_height, z_origin,
                                                                       door_azimuth, [0, 0, 0, 0]), model)
      sub_surface.setName(door_id)
      sub_surface.setSurface(surface)
      sub_surface.setSubSurfaceType("Door")

      # Apply construction
      ufactor = 1.0 / door_values[:r_value]

      success = Constructions.apply_door(runner, model, [sub_surface], "Door", ufactor)
      return false if not success
    end

    success = apply_adiabatic_construction(runner, model, surfaces, "wall")
    return false if not success

    return true
  end

  def self.apply_adiabatic_construction(runner, model, surfaces, type)
    # Arbitrary construction for heat capacitance.
    # Only applies to surfaces where outside boundary conditioned is
    # adiabatic or surface net area is near zero.

    if type == "wall"

      success = Constructions.apply_wood_stud_wall(runner, model, surfaces, "AdiabaticWallConstruction",
                                                   0, 1, 3.5, true, 0.1, 0.5, 0, 999,
                                                   Material.ExtFinishStuccoMedDark)
      return false if not success

    elsif type == "floor"

      success = Constructions.apply_floor(runner, model, surfaces, "AdiabaticFloorConstruction",
                                          0, 1, 0.07, 5.5, 0.75, 999,
                                          Material.FloorWood, Material.CoveringBare)
      return false if not success

    elsif type == "roof"

      success = Constructions.apply_open_cavity_roof(runner, model, surfaces, "AdiabaticRoofConstruction",
                                                     0, 1, 7.25, 0.07, 7.25, 0.75, 999,
                                                     Material.RoofingAsphaltShinglesMed, false)
      return false if not success

    end

    return true
  end

  def self.add_hot_water_and_appliances(runner, model, building, weather, spaces, loop_dhws)
    # Clothes Washer
    clothes_washer_values = HPXML.get_clothes_washer_values(clothes_washer: building.elements["BuildingDetails/Appliances/ClothesWasher"])
    if not clothes_washer_values.nil?
      cw_space = get_space_from_location(clothes_washer_values[:location], "ClothesWasher", model, spaces)
      cw_ler = clothes_washer_values[:rated_annual_kwh]
      cw_elec_rate = clothes_washer_values[:label_electric_rate]
      cw_gas_rate = clothes_washer_values[:label_gas_rate]
      cw_agc = clothes_washer_values[:label_annual_gas_cost]
      cw_cap = clothes_washer_values[:capacity]
      cw_mef = clothes_washer_values[:modified_energy_factor]
      if cw_mef.nil?
        cw_mef = HotWaterAndAppliances.calc_clothes_washer_mef_from_imef(clothes_washer_values[:integrated_modified_energy_factor])
      end
    else
      cw_mef = cw_ler = cw_elec_rate = cw_gas_rate = cw_agc = cw_cap = cw_space = nil
    end

    # Clothes Dryer
    clothes_dryer_values = HPXML.get_clothes_dryer_values(clothes_dryer: building.elements["BuildingDetails/Appliances/ClothesDryer"])
    if not clothes_dryer_values.nil?
      cd_space = get_space_from_location(clothes_dryer_values[:location], "ClothesDryer", model, spaces)
      cd_fuel = to_beopt_fuel(clothes_dryer_values[:fuel_type])
      cd_control = clothes_dryer_values[:control_type]
      cd_ef = clothes_dryer_values[:energy_factor]
      if cd_ef.nil?
        cd_ef = HotWaterAndAppliances.calc_clothes_dryer_ef_from_cef(clothes_dryer_values[:combined_energy_factor])
      end
    else
      cd_ef = cd_control = cd_fuel = cd_space = nil
    end

    # Dishwasher
    dishwasher_values = HPXML.get_dishwasher_values(dishwasher: building.elements["BuildingDetails/Appliances/Dishwasher"])
    if not dishwasher_values.nil?
      dw_cap = dishwasher_values[:place_setting_capacity]
      dw_ef = dishwasher_values[:energy_factor]
      if dw_ef.nil?
        dw_ef = HotWaterAndAppliances.calc_dishwasher_ef_from_annual_kwh(dishwasher_values[:rated_annual_kwh])
      end
    else
      dw_ef = dw_cap = nil
    end

    # Refrigerator
    refrigerator_values = HPXML.get_refrigerator_values(refrigerator: building.elements["BuildingDetails/Appliances/Refrigerator"])
    if not refrigerator_values.nil?
      fridge_space = get_space_from_location(refrigerator_values[:location], "Refrigerator", model, spaces)
      fridge_annual_kwh = refrigerator_values[:rated_annual_kwh]
    else
      fridge_annual_kwh = fridge_space = nil
    end

    # Cooking Range/Oven
    cooking_range_values = HPXML.get_cooking_range_values(cooking_range: building.elements["BuildingDetails/Appliances/CookingRange"])
    oven_values = HPXML.get_oven_values(oven: building.elements["BuildingDetails/Appliances/Oven"])
    if not cooking_range_values.nil? and not oven_values.nil?
      cook_fuel_type = to_beopt_fuel(cooking_range_values[:fuel_type])
      cook_is_induction = cooking_range_values[:is_induction]
      oven_is_convection = oven_values[:is_convection]
    else
      cook_fuel_type = cook_is_induction = oven_is_convection = nil
    end

    wh = building.elements["BuildingDetails/Systems/WaterHeating"]

    # Fixtures
    has_low_flow_fixtures = false
    if not wh.nil?
      low_flow_fixtures_list = []
      wh.elements.each("WaterFixture[WaterFixtureType='shower head' or WaterFixtureType='faucet']") do |wf|
        water_fixture_values = HPXML.get_water_fixture_values(water_fixture: wf)
        low_flow_fixtures_list << water_fixture_values[:low_flow]
      end
      low_flow_fixtures_list.uniq!
      if low_flow_fixtures_list.size == 1 and low_flow_fixtures_list[0]
        has_low_flow_fixtures = true
      end
    end

    # Distribution
    if not wh.nil?
      dist = wh.elements["HotWaterDistribution"]
      hot_water_distribution_values = HPXML.get_hot_water_distribution_values(hot_water_distribution: wh.elements["HotWaterDistribution"])
      dist_type = hot_water_distribution_values[:system_type].downcase
      if dist_type == "standard"
        std_pipe_length = hot_water_distribution_values[:standard_piping_length]
        recirc_loop_length = nil
        recirc_branch_length = nil
        recirc_control_type = nil
        recirc_pump_power = nil
      elsif dist_type == "recirculation"
        recirc_loop_length = hot_water_distribution_values[:recirculation_piping_length]
        recirc_branch_length = hot_water_distribution_values[:recirculation_branch_piping_length]
        recirc_control_type = hot_water_distribution_values[:recirculation_control_type]
        recirc_pump_power = hot_water_distribution_values[:recirculation_pump_power]
        std_pipe_length = nil
      end
      pipe_r = hot_water_distribution_values[:pipe_r_value]
    end

    # Drain Water Heat Recovery
    dwhr_present = false
    dwhr_facilities_connected = nil
    dwhr_is_equal_flow = nil
    dwhr_efficiency = nil
    if not wh.nil?
      if XMLHelper.has_element(dist, "DrainWaterHeatRecovery")
        dwhr_present = true
        dwhr_facilities_connected = hot_water_distribution_values[:dwhr_facilities_connected]
        dwhr_is_equal_flow = hot_water_distribution_values[:dwhr_equal_flow]
        dwhr_efficiency = hot_water_distribution_values[:dwhr_efficiency]
      end
    end

    # Water Heater
    dhw_loop_fracs = {}
    if not wh.nil?
      wh.elements.each("WaterHeatingSystem") do |dhw|
        water_heating_system_values = HPXML.get_water_heating_system_values(water_heating_system: dhw)

        orig_plant_loops = model.getPlantLoops

        space = get_space_from_location(water_heating_system_values[:location], "WaterHeatingSystem", model, spaces)
        setpoint_temp = Waterheater.get_default_hot_water_temperature(@eri_version)
        wh_type = water_heating_system_values[:water_heater_type]
        fuel = water_heating_system_values[:fuel_type]

        ef = water_heating_system_values[:energy_factor]
        if ef.nil?
          uef = water_heating_system_values[:uniform_energy_factor]
          ef = Waterheater.calc_ef_from_uef(uef, to_beopt_wh_type(wh_type), to_beopt_fuel(fuel))
        end

        ec_adj = HotWaterAndAppliances.get_dist_energy_consumption_adjustment(@has_uncond_bsmnt, @cfa, @ncfl,
                                                                              dist_type, recirc_control_type,
                                                                              pipe_r, std_pipe_length, recirc_loop_length)

        dhw_load_frac = water_heating_system_values[:fraction_dhw_load_served]

        if wh_type == "storage water heater"

          tank_vol = water_heating_system_values[:tank_volume]
          if fuel != "electricity"
            re = water_heating_system_values[:recovery_efficiency]
          else
            re = 0.98
          end
          capacity_kbtuh = water_heating_system_values[:heating_capacity] / 1000.0
          oncycle_power = 0.0
          offcycle_power = 0.0
          success = Waterheater.apply_tank(model, runner, nil, space, to_beopt_fuel(fuel),
                                           capacity_kbtuh, tank_vol, ef, re, setpoint_temp,
                                           oncycle_power, offcycle_power, ec_adj, @nbeds)
          return false if not success

        elsif wh_type == "instantaneous water heater"

          cycling_derate = water_heating_system_values[:performance_adjustment]
          if cycling_derate.nil?
            cycling_derate = Waterheater.get_tankless_cycling_derate()
          end

          capacity_kbtuh = 100000000.0
          oncycle_power = 0.0
          offcycle_power = 0.0
          success = Waterheater.apply_tankless(model, runner, nil, space, to_beopt_fuel(fuel),
                                               capacity_kbtuh, ef, cycling_derate,
                                               setpoint_temp, oncycle_power, offcycle_power, ec_adj,
                                               @nbeds)
          return false if not success

        elsif wh_type == "heat pump water heater"

          tank_vol = water_heating_system_values[:tank_volume]
          e_cap = 4.5 # FIXME
          min_temp = 45.0 # FIXME
          max_temp = 120.0 # FIXME
          cap = 0.5 # FIXME
          cop = 2.8 # FIXME
          shr = 0.88 # FIXME
          airflow_rate = 181.0 # FIXME
          fan_power = 0.0462 # FIXME
          parasitics = 3.0 # FIXME
          tank_ua = 3.9 # FIXME
          int_factor = 1.0 # FIXME
          temp_depress = 0.0 # FIXME
          ducting = "none"
          # FIXME: Use ef, ec_adj
          success = Waterheater.apply_heatpump(model, runner, nil, space, weather,
                                               e_cap, tank_vol, setpoint_temp, min_temp, max_temp,
                                               cap, cop, shr, airflow_rate, fan_power,
                                               parasitics, tank_ua, int_factor, temp_depress,
                                               @nbeds, ducting)
          return false if not success

        else

          fail "Unhandled water heater (#{wh_type})."

        end

        new_plant_loop = (model.getPlantLoops - orig_plant_loops)[0]
        dhw_loop_fracs[new_plant_loop] = dhw_load_frac

        update_loop_dhws(loop_dhws, model, dhw, orig_plant_loops)
      end
    end

    wh_setpoint = Waterheater.get_default_hot_water_temperature(@eri_version)
    living_space = get_space_of_type(spaces, Constants.SpaceTypeLiving)
    success = HotWaterAndAppliances.apply(model, runner, weather, living_space,
                                          @cfa, @nbeds, @ncfl, @has_uncond_bsmnt, wh_setpoint,
                                          cw_mef, cw_ler, cw_elec_rate, cw_gas_rate,
                                          cw_agc, cw_cap, cw_space, cd_fuel, cd_ef, cd_control,
                                          cd_space, dw_ef, dw_cap, fridge_annual_kwh, fridge_space,
                                          cook_fuel_type, cook_is_induction, oven_is_convection,
                                          has_low_flow_fixtures, dist_type, pipe_r,
                                          std_pipe_length, recirc_loop_length,
                                          recirc_branch_length, recirc_control_type,
                                          recirc_pump_power, dwhr_present,
                                          dwhr_facilities_connected, dwhr_is_equal_flow,
                                          dwhr_efficiency, dhw_loop_fracs, @eri_version)
    return false if not success

    return true
  end

  def self.add_cooling_system(runner, model, building, loop_hvacs, zone_hvacs, use_only_ideal_air)
    return true if use_only_ideal_air

    building.elements.each("BuildingDetails/Systems/HVAC/HVACPlant/CoolingSystem") do |clgsys|
      cooling_system_values = HPXML.get_cooling_system_values(cooling_system: clgsys)

      clg_type = cooling_system_values[:cooling_system_type]

      cool_capacity_btuh = cooling_system_values[:cooling_capacity]
      if cool_capacity_btuh <= 0.0
        cool_capacity_btuh = Constants.SizingAuto
      end

      load_frac = cooling_system_values[:fraction_cool_load_served]
      sequential_load_frac = load_frac / @total_frac_remaining_cool_load_served # Fraction of remaining load served by this system
      @total_frac_remaining_cool_load_served -= load_frac

      dse_heat, dse_cool, has_dse = get_dse(building, cooling_system_values)

      orig_air_loops = model.getAirLoopHVACs
      orig_plant_loops = model.getPlantLoops
      orig_zone_hvacs = get_zone_hvacs(model)

      if clg_type == "central air conditioning"

        # FIXME: Generalize
        seer = cooling_system_values[:cooling_efficiency_seer]
        num_speeds = get_ac_num_speeds(seer)
        crankcase_kw = 0.05 # From RESNET Publication No. 002-2017
        crankcase_temp = 50.0 # From RESNET Publication No. 002-2017
        attached_heating_system = get_attached_system(cooling_system_values, building,
                                                      "HeatingSystem", loop_hvacs)

        if num_speeds == "1-Speed"

          eers = [0.82 * seer + 0.64]
          shrs = [0.73]
          fan_power_installed = get_fan_power_installed(seer)
          success = HVAC.apply_central_ac_1speed(model, runner, seer, eers, shrs,
                                                 fan_power_installed, crankcase_kw, crankcase_temp,
                                                 cool_capacity_btuh, dse_cool, load_frac,
                                                 sequential_load_frac, attached_heating_system,
                                                 @control_slave_zones_hash)
          return false if not success

        elsif num_speeds == "2-Speed"

          eers = [0.83 * seer + 0.15, 0.56 * seer + 3.57]
          shrs = [0.71, 0.73]
          capacity_ratios = [0.72, 1.0]
          fan_speed_ratios = [0.86, 1.0]
          fan_power_installed = get_fan_power_installed(seer)
          success = HVAC.apply_central_ac_2speed(model, runner, seer, eers, shrs,
                                                 capacity_ratios, fan_speed_ratios,
                                                 fan_power_installed, crankcase_kw, crankcase_temp,
                                                 cool_capacity_btuh, dse_cool, load_frac,
                                                 sequential_load_frac, attached_heating_system,
                                                 @control_slave_zones_hash)
          return false if not success

        elsif num_speeds == "Variable-Speed"

          eers = [0.80 * seer, 0.75 * seer, 0.65 * seer, 0.60 * seer]
          shrs = [0.98, 0.82, 0.745, 0.77]
          capacity_ratios = [0.36, 0.64, 1.0, 1.16]
          fan_speed_ratios = [0.51, 0.84, 1.0, 1.19]
          fan_power_installed = get_fan_power_installed(seer)
          success = HVAC.apply_central_ac_4speed(model, runner, seer, eers, shrs,
                                                 capacity_ratios, fan_speed_ratios,
                                                 fan_power_installed, crankcase_kw, crankcase_temp,
                                                 cool_capacity_btuh, dse_cool, load_frac,
                                                 sequential_load_frac, attached_heating_system,
                                                 @control_slave_zones_hash)
          return false if not success

        else

          fail "Unexpected number of speeds (#{num_speeds}) for cooling system."

        end

      elsif clg_type == "room air conditioner"

        eer = cooling_system_values[:cooling_efficiency_eer]
        shr = 0.65
        airflow_rate = 350.0
        success = HVAC.apply_room_ac(model, runner, eer, shr,
                                     airflow_rate, cool_capacity_btuh, load_frac,
                                     sequential_load_frac, @control_slave_zones_hash)
        return false if not success

      end

      update_loop_hvacs(loop_hvacs, zone_hvacs, model, clgsys, orig_air_loops, orig_plant_loops, orig_zone_hvacs)
    end

    return true
  end

  def self.add_heating_system(runner, model, building, loop_hvacs, zone_hvacs, use_only_ideal_air)
    return true if use_only_ideal_air

    building.elements.each("BuildingDetails/Systems/HVAC/HVACPlant/HeatingSystem") do |htgsys|
      heating_system_values = HPXML.get_heating_system_values(heating_system: htgsys)

      fuel = to_beopt_fuel(heating_system_values[:heating_system_fuel])

      heat_capacity_btuh = heating_system_values[:heating_capacity]
      if heat_capacity_btuh <= 0.0
        heat_capacity_btuh = Constants.SizingAuto
      end
      htg_type = heating_system_values[:heating_system_type]

      load_frac = heating_system_values[:fraction_heat_load_served]
      sequential_load_frac = load_frac / @total_frac_remaining_heat_load_served # Fraction of remaining load served by this system
      @total_frac_remaining_heat_load_served -= load_frac

      dse_heat, dse_cool, has_dse = get_dse(building, heating_system_values)

      orig_air_loops = model.getAirLoopHVACs
      orig_plant_loops = model.getPlantLoops
      orig_zone_hvacs = get_zone_hvacs(model)

      if htg_type == "Furnace"

        afue = heating_system_values[:heating_efficiency_afue]
        fan_power = 0.5 # For fuel furnaces, will be overridden by EAE later
        attached_cooling_system = get_attached_system(heating_system_values, building,
                                                      "CoolingSystem", loop_hvacs)
        success = HVAC.apply_furnace(model, runner, fuel, afue,
                                     heat_capacity_btuh, fan_power, dse_heat,
                                     load_frac, sequential_load_frac,
                                     attached_cooling_system, @control_slave_zones_hash)
        return false if not success

      elsif htg_type == "WallFurnace"

        afue = heating_system_values[:heating_efficiency_afue]
        fan_power = 0.0
        airflow_rate = 0.0
        success = HVAC.apply_unit_heater(model, runner, fuel,
                                         afue, heat_capacity_btuh, fan_power,
                                         airflow_rate, load_frac,
                                         sequential_load_frac, @control_slave_zones_hash)
        return false if not success

      elsif htg_type == "Boiler"

        system_type = Constants.BoilerTypeForcedDraft
        afue = heating_system_values[:heating_efficiency_afue]
        oat_reset_enabled = false
        oat_high = nil
        oat_low = nil
        oat_hwst_high = nil
        oat_hwst_low = nil
        design_temp = 180.0
        success = HVAC.apply_boiler(model, runner, fuel, system_type, afue,
                                    oat_reset_enabled, oat_high, oat_low, oat_hwst_high, oat_hwst_low,
                                    heat_capacity_btuh, design_temp, dse_heat, load_frac,
                                    sequential_load_frac, @control_slave_zones_hash)
        return false if not success

      elsif htg_type == "ElectricResistance"

        efficiency = heating_system_values[:heating_efficiency_percent]
        success = HVAC.apply_electric_baseboard(model, runner, efficiency,
                                                heat_capacity_btuh, load_frac,
                                                sequential_load_frac, @control_slave_zones_hash)
        return false if not success

      elsif htg_type == "Stove"

        efficiency = heating_system_values[:heating_efficiency_percent]
        airflow_rate = 125.0 # cfm/ton; doesn't affect energy consumption
        fan_power = 0.5 # For fuel equipment, will be overridden by EAE later
        success = HVAC.apply_unit_heater(model, runner, fuel,
                                         efficiency, heat_capacity_btuh, fan_power,
                                         airflow_rate, load_frac,
                                         sequential_load_frac, @control_slave_zones_hash)
        return false if not success

      end

      update_loop_hvacs(loop_hvacs, zone_hvacs, model, htgsys, orig_air_loops, orig_plant_loops, orig_zone_hvacs)
    end

    return true
  end

  def self.add_heat_pump(runner, model, building, weather, loop_hvacs, zone_hvacs, use_only_ideal_air)
    return true if use_only_ideal_air

    building.elements.each("BuildingDetails/Systems/HVAC/HVACPlant/HeatPump") do |hp|
      heat_pump_values = HPXML.get_heat_pump_values(heat_pump: hp)

      hp_type = heat_pump_values[:heat_pump_type]

      cool_capacity_btuh = heat_pump_values[:cooling_capacity]
      if cool_capacity_btuh.nil?
        cool_capacity_btuh = Constants.SizingAuto
      end

      load_frac_heat = heat_pump_values[:fraction_heat_load_served]
      sequential_load_frac_heat = load_frac_heat / @total_frac_remaining_heat_load_served # Fraction of remaining load served by this system
      @total_frac_remaining_heat_load_served -= load_frac_heat

      load_frac_cool = heat_pump_values[:fraction_cool_load_served]
      sequential_load_frac_cool = load_frac_cool / @total_frac_remaining_cool_load_served # Fraction of remaining load served by this system
      @total_frac_remaining_cool_load_served -= load_frac_cool

      backup_heat_capacity_btuh = heat_pump_values[:backup_heating_capacity] # TODO: Require in ERI Use Case?
      if backup_heat_capacity_btuh.nil?
        backup_heat_capacity_btuh = Constants.SizingAuto
      end

      dse_heat, dse_cool, has_dse = get_dse(building, heat_pump_values)
      if dse_heat != dse_cool
        # TODO: Can we remove this since we use separate airloops for
        # heating and cooling?
        fail "Cannot handle different distribution system efficiency (DSE) values for heating and cooling."
      end

      orig_air_loops = model.getAirLoopHVACs
      orig_plant_loops = model.getPlantLoops
      orig_zone_hvacs = get_zone_hvacs(model)

      if hp_type == "air-to-air"

        seer = heat_pump_values[:cooling_efficiency_seer]
        hspf = heat_pump_values[:heating_efficiency_hspf]

        if load_frac_cool > 0
          num_speeds = get_ashp_num_speeds_by_seer(seer)
        else
          num_speeds = get_ashp_num_speeds_by_hspf(hspf)
        end

        crankcase_kw = 0.05 # From RESNET Publication No. 002-2017
        crankcase_temp = 50.0 # From RESNET Publication No. 002-2017

        if num_speeds == "1-Speed"

          eers = [0.80 * seer + 1.00]
          cops = [0.57 * hspf - 1.30]
          shrs = [0.73]
          fan_power_installed = get_fan_power_installed(seer)
          min_temp = 0.0
          supplemental_efficiency = 1.0
          success = HVAC.apply_central_ashp_1speed(model, runner, seer, hspf, eers, cops, shrs,
                                                   fan_power_installed, min_temp, crankcase_kw, crankcase_temp,
                                                   cool_capacity_btuh, supplemental_efficiency,
                                                   backup_heat_capacity_btuh, dse_heat,
                                                   load_frac_heat, load_frac_cool,
                                                   sequential_load_frac_heat, sequential_load_frac_cool,
                                                   @control_slave_zones_hash)
          return false if not success

        elsif num_speeds == "2-Speed"

          eers = [0.78 * seer + 0.60, 0.68 * seer + 1.00]
          cops = [0.60 * hspf - 1.40, 0.50 * hspf - 0.94]
          shrs = [0.71, 0.724]
          capacity_ratios = [0.72, 1.0]
          fan_speed_ratios_cooling = [0.86, 1.0]
          fan_speed_ratios_heating = [0.8, 1.0]
          fan_power_installed = get_fan_power_installed(seer)
          min_temp = 0.0
          supplemental_efficiency = 1.0
          success = HVAC.apply_central_ashp_2speed(model, runner, seer, hspf, eers, cops, shrs,
                                                   capacity_ratios, fan_speed_ratios_cooling, fan_speed_ratios_heating,
                                                   fan_power_installed, min_temp, crankcase_kw, crankcase_temp,
                                                   cool_capacity_btuh, supplemental_efficiency,
                                                   backup_heat_capacity_btuh, dse_heat,
                                                   load_frac_heat, load_frac_cool,
                                                   sequential_load_frac_heat, sequential_load_frac_cool,
                                                   @control_slave_zones_hash)
          return false if not success

        elsif num_speeds == "Variable-Speed"

          eers = [0.80 * seer, 0.75 * seer, 0.65 * seer, 0.60 * seer]
          cops = [0.48 * hspf, 0.45 * hspf, 0.39 * hspf, 0.39 * hspf]
          shrs = [0.84, 0.79, 0.76, 0.77]
          capacity_ratios = [0.49, 0.67, 1.0, 1.2]
          fan_speed_ratios_cooling = [0.7, 0.9, 1.0, 1.26]
          fan_speed_ratios_heating = [0.74, 0.92, 1.0, 1.22]
          fan_power_installed = get_fan_power_installed(seer)
          min_temp = 0.0
          supplemental_efficiency = 1.0
          success = HVAC.apply_central_ashp_4speed(model, runner, seer, hspf, eers, cops, shrs,
                                                   capacity_ratios, fan_speed_ratios_cooling, fan_speed_ratios_heating,
                                                   fan_power_installed, min_temp, crankcase_kw, crankcase_temp,
                                                   cool_capacity_btuh, supplemental_efficiency,
                                                   backup_heat_capacity_btuh, dse_heat,
                                                   load_frac_heat, load_frac_cool,
                                                   sequential_load_frac_heat, sequential_load_frac_cool,
                                                   @control_slave_zones_hash)
          return false if not success

        else

          fail "Unexpected number of speeds (#{num_speeds}) for heat pump system."

        end

      elsif hp_type == "mini-split"

        # FIXME: Generalize
        seer = heat_pump_values[:cooling_efficiency_seer]
        hspf = heat_pump_values[:heating_efficiency_hspf]
        shr = 0.73
        min_cooling_capacity = 0.4
        max_cooling_capacity = 1.2
        min_cooling_airflow_rate = 200.0
        max_cooling_airflow_rate = 425.0
        min_heating_capacity = 0.3
        max_heating_capacity = 1.2
        min_heating_airflow_rate = 200.0
        max_heating_airflow_rate = 400.0
        heating_capacity_offset = 2300.0
        cap_retention_frac = 0.25
        cap_retention_temp = -5.0
        pan_heater_power = 0.0
        fan_power = 0.07
        is_ducted = (XMLHelper.has_element(hp, "DistributionSystem") and not has_dse)
        supplemental_efficiency = 1.0
        success = HVAC.apply_mshp(model, runner, seer, hspf, shr,
                                  min_cooling_capacity, max_cooling_capacity,
                                  min_cooling_airflow_rate, max_cooling_airflow_rate,
                                  min_heating_capacity, max_heating_capacity,
                                  min_heating_airflow_rate, max_heating_airflow_rate,
                                  heating_capacity_offset, cap_retention_frac,
                                  cap_retention_temp, pan_heater_power, fan_power,
                                  is_ducted, cool_capacity_btuh,
                                  supplemental_efficiency, backup_heat_capacity_btuh,
                                  dse_heat, load_frac_heat, load_frac_cool,
                                  sequential_load_frac_heat, sequential_load_frac_cool,
                                  @control_slave_zones_hash)
        return false if not success

      elsif hp_type == "ground-to-air"

        # FIXME: Generalize
        eer = heat_pump_values[:cooling_efficiency_eer]
        cop = heat_pump_values[:heating_efficiency_cop]
        shr = 0.732
        ground_conductivity = 0.6
        grout_conductivity = 0.4
        bore_config = Constants.SizingAuto
        bore_holes = Constants.SizingAuto
        bore_depth = Constants.SizingAuto
        bore_spacing = 20.0
        bore_diameter = 5.0
        pipe_size = 0.75
        ground_diffusivity = 0.0208
        fluid_type = Constants.FluidPropyleneGlycol
        frac_glycol = 0.3
        design_delta_t = 10.0
        pump_head = 50.0
        u_tube_leg_spacing = 0.9661
        u_tube_spacing_type = "b"
        fan_power = 0.5
        heat_pump_capacity = cool_capacity_btuh
        supplemental_efficiency = 1
        supplemental_capacity = backup_heat_capacity_btuh
        success = HVAC.apply_gshp(model, runner, weather, cop, eer, shr,
                                  ground_conductivity, grout_conductivity,
                                  bore_config, bore_holes, bore_depth,
                                  bore_spacing, bore_diameter, pipe_size,
                                  ground_diffusivity, fluid_type, frac_glycol,
                                  design_delta_t, pump_head,
                                  u_tube_leg_spacing, u_tube_spacing_type,
                                  fan_power, heat_pump_capacity, supplemental_efficiency,
                                  supplemental_capacity, dse_heat,
                                  load_frac_heat, load_frac_cool,
                                  sequential_load_frac_heat, sequential_load_frac_cool,
                                  @control_slave_zones_hash)
        return false if not success

      end

      update_loop_hvacs(loop_hvacs, zone_hvacs, model, hp, orig_air_loops, orig_plant_loops, orig_zone_hvacs)
    end

    return true
  end

  def self.add_residual_hvac(runner, model, building, use_only_ideal_air)
    if use_only_ideal_air
      success = HVAC.apply_ideal_air_loads_heating(model, runner, 1, 1, @control_slave_zones_hash)
      return false if not success

      success = HVAC.apply_ideal_air_loads_cooling(model, runner, 1, 1, @control_slave_zones_hash)
      return false if not success

      return true
    end

    # Residual heating
    htg_load_frac = building.elements["sum(BuildingDetails/Systems/HVAC/HVACPlant/HeatingSystem/FractionHeatLoadServed)"]
    htg_load_frac += building.elements["sum(BuildingDetails/Systems/HVAC/HVACPlant/HeatPump/FractionHeatLoadServed)"]
    residual_heat_load_served = 1.0 - htg_load_frac
    if residual_heat_load_served > 0.02 and residual_heat_load_served < 1
      success = HVAC.apply_ideal_air_loads_heating(model, runner, residual_heat_load_served,
                                                   residual_heat_load_served, @control_slave_zones_hash)
      return false if not success
    end
    @total_frac_remaining_heat_load_served -= residual_heat_load_served

    # Residual cooling
    clg_load_frac = building.elements["sum(BuildingDetails/Systems/HVAC/HVACPlant/CoolingSystem/FractionCoolLoadServed)"]
    clg_load_frac += building.elements["sum(BuildingDetails/Systems/HVAC/HVACPlant/HeatPump/FractionCoolLoadServed)"]
    residual_cool_load_served = 1.0 - clg_load_frac
    if residual_cool_load_served > 0.02 and residual_cool_load_served < 1
      success = HVAC.apply_ideal_air_loads_cooling(model, runner, residual_cool_load_served,
                                                   residual_cool_load_served, @control_slave_zones_hash)
      return false if not success
    end
    @total_frac_remaining_cool_load_served -= residual_cool_load_served

    return true
  end

  def self.add_setpoints(runner, model, building, weather, spaces)
    hvac_control_values = HPXML.get_hvac_control_values(hvac_control: building.elements["BuildingDetails/Systems/HVAC/HVACControl"])
    return true if hvac_control_values.nil?

    conditioned_zones = get_spaces_of_type(spaces, [Constants.SpaceTypeLiving, Constants.SpaceTypeConditionedBasement]).map { |z| z.thermalZone.get }.compact

    control_type = hvac_control_values[:control_type]
    heating_temp = hvac_control_values[:setpoint_temp_heating_season]
    if not heating_temp.nil? # Use provided value
      htg_weekday_setpoints = [[heating_temp] * 24] * 12
    else # Use ERI default
      htg_sp, htg_setback_sp, htg_setback_hrs_per_week, htg_setback_start_hr = HVAC.get_default_heating_setpoint(control_type)
      if htg_setback_sp.nil?
        htg_weekday_setpoints = [[htg_sp] * 24] * 12
      else
        htg_weekday_setpoints = [[htg_sp] * 24] * 12
        (0..11).to_a.each do |m|
          for hr in htg_setback_start_hr..htg_setback_start_hr + Integer(htg_setback_hrs_per_week / 7.0) - 1
            htg_weekday_setpoints[m][hr % 24] = htg_setback_sp
          end
        end
      end
    end
    htg_weekend_setpoints = htg_weekday_setpoints
    htg_use_auto_season = false
    htg_season_start_month = 1
    htg_season_end_month = 12
    success = HVAC.apply_heating_setpoints(model, runner, weather, htg_weekday_setpoints, htg_weekend_setpoints,
                                           htg_use_auto_season, htg_season_start_month, htg_season_end_month,
                                           conditioned_zones)
    return false if not success

    cooling_temp = hvac_control_values[:setpoint_temp_cooling_season]
    if not cooling_temp.nil? # Use provided value
      clg_weekday_setpoints = [[cooling_temp] * 24] * 12
    else # Use ERI default
      clg_sp, clg_setup_sp, clg_setup_hrs_per_week, clg_setup_start_hr = HVAC.get_default_cooling_setpoint(control_type)
      if clg_setup_sp.nil?
        clg_weekday_setpoints = [[clg_sp] * 24] * 12
      else
        clg_weekday_setpoints = [[clg_sp] * 24] * 12
        (0..11).to_a.each do |m|
          for hr in clg_setup_start_hr..clg_setup_start_hr + Integer(clg_setup_hrs_per_week / 7.0) - 1
            clg_weekday_setpoints[m][hr % 24] = clg_setup_sp
          end
        end
      end
    end
    # Apply ceiling fan offset?
    if not building.elements["BuildingDetails/Lighting/CeilingFan"].nil?
      cooling_setpoint_offset = 0.5 # deg-F
      monthly_avg_temp_control = 63.0 # deg-F
      weather.data.MonthlyAvgDrybulbs.each_with_index do |val, m|
        next unless val > monthly_avg_temp_control

        clg_weekday_setpoints[m] = [clg_weekday_setpoints[m], Array.new(24, cooling_setpoint_offset)].transpose.map { |i| i.reduce(:+) }
      end
    end
    clg_weekend_setpoints = clg_weekday_setpoints
    clg_use_auto_season = false
    clg_season_start_month = 1
    clg_season_end_month = 12
    success = HVAC.apply_cooling_setpoints(model, runner, weather, clg_weekday_setpoints, clg_weekend_setpoints,
                                           clg_use_auto_season, clg_season_start_month, clg_season_end_month,
                                           conditioned_zones)
    return false if not success

    return true
  end

  def self.add_ceiling_fans(runner, model, building, spaces)
    ceiling_fan_values = HPXML.get_ceiling_fan_values(ceiling_fan: building.elements["BuildingDetails/Lighting/CeilingFan"])
    return true if ceiling_fan_values.nil?

    medium_cfm = 3000.0
    weekday_sch = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0]
    weekend_sch = weekday_sch
    hrs_per_day = weekday_sch.inject { |sum, n| sum + n }

    cfm_per_w = ceiling_fan_values[:efficiency]
    if cfm_per_w.nil?
      fan_power_w = HVAC.get_default_ceiling_fan_power()
      cfm_per_w = medium_cfm / fan_power_w
    end
    quantity = ceiling_fan_values[:quantity]
    if quantity.nil?
      quantity = HVAC.get_default_ceiling_fan_quantity(@nbeds)
    end
    annual_kwh = UnitConversions.convert(quantity * medium_cfm / cfm_per_w * hrs_per_day * 365.0, "Wh", "kWh")

    conditioned_spaces = get_spaces_of_type(spaces, [Constants.SpaceTypeLiving, Constants.SpaceTypeConditionedBasement])
    success = HVAC.apply_ceiling_fans(model, runner, annual_kwh, weekday_sch, weekend_sch,
                                      @cfa, conditioned_spaces)
    return false if not success

    return true
  end

  def self.get_dse(building, system_values)
    dist_id = system_values[:distribution_system_idref]
    if dist_id.nil? # No distribution system
      return 1.0, 1.0, false
    end

    # Get attached distribution system
    attached_dist = nil
    found_attached_dist = nil
    annual_cooling_dse = nil
    annual_heating_dse = nil
    building.elements.each("BuildingDetails/Systems/HVAC/HVACDistribution") do |dist|
      hvac_distribution_values = HPXML.get_hvac_distribution_values(hvac_distribution: dist)
      next if dist_id != hvac_distribution_values[:id]

      found_attached_dist = true
      next if hvac_distribution_values[:distribution_system_type] != 'DSE'

      attached_dist = dist
      annual_cooling_dse = hvac_distribution_values[:annual_cooling_dse]
      annual_heating_dse = hvac_distribution_values[:annual_heating_dse]
    end

    if not found_attached_dist
      fail "Attached HVAC distribution system '#{dist_id}' cannot be found for HVAC system '#{system_values[:id]}'."
    end

    if attached_dist.nil? # No attached DSEs for system
      return 1.0, 1.0, false
    end

    dse_cool = annual_cooling_dse
    dse_heat = annual_heating_dse
    return dse_heat, dse_cool, true
  end

  def self.get_zone_hvacs(model)
    zone_hvacs = []
    model.getThermalZones.each do |zone|
      zone.equipment.each do |zone_hvac|
        next unless zone_hvac.to_ZoneHVACComponent.is_initialized

        zone_hvacs << zone_hvac
      end
    end
    return zone_hvacs
  end

  def self.update_loop_hvacs(loop_hvacs, zone_hvacs, model, sys, orig_air_loops, orig_plant_loops, orig_zone_hvacs)
    sys_id = sys.elements["SystemIdentifier"].attributes["id"]
    loop_hvacs[sys_id] = []
    zone_hvacs[sys_id] = []

    model.getAirLoopHVACs.each do |air_loop|
      next if orig_air_loops.include? air_loop # Only include newly added air loops

      loop_hvacs[sys_id] << air_loop
    end

    model.getPlantLoops.each do |plant_loop|
      next if orig_plant_loops.include? plant_loop # Only include newly added plant loops

      loop_hvacs[sys_id] << plant_loop
    end

    get_zone_hvacs(model).each do |zone_hvac|
      next if orig_zone_hvacs.include? zone_hvac

      zone_hvacs[sys_id] << zone_hvac
    end

    loop_hvacs.each do |sys_id, loops|
      next if not loops.empty?

      loop_hvacs.delete(sys_id)
    end

    zone_hvacs.each do |sys_id, hvacs|
      next if not hvacs.empty?

      zone_hvacs.delete(sys_id)
    end
  end

  def self.update_loop_dhws(loop_dhws, model, sys, orig_plant_loops)
    sys_id = sys.elements["SystemIdentifier"].attributes["id"]
    loop_dhws[sys_id] = []

    model.getPlantLoops.each do |plant_loop|
      next if orig_plant_loops.include? plant_loop # Only include newly added plant loops

      loop_dhws[sys_id] << plant_loop
    end

    loop_dhws.each do |sys_id, loops|
      next if not loops.empty?

      loop_dhws.delete(sys_id)
    end
  end

  def self.add_mels(runner, model, building, spaces)
    # Misc
    plug_load_values = HPXML.get_plug_load_values(plug_load: building.elements["BuildingDetails/MiscLoads/PlugLoad[PlugLoadType='other']"])
    if not plug_load_values.nil?
      misc_annual_kwh = plug_load_values[:kWh_per_year]
      if misc_annual_kwh.nil?
        misc_annual_kwh = MiscLoads.get_residual_mels_values(@cfa)[0]
      end

      misc_sens_frac = plug_load_values[:frac_sensible]
      if misc_sens_frac.nil?
        misc_sens_frac = MiscLoads.get_residual_mels_values(@cfa)[1]
      end

      misc_lat_frac = plug_load_values[:frac_latent]
      if misc_lat_frac.nil?
        misc_lat_frac = MiscLoads.get_residual_mels_values(@cfa)[2]
      end

      misc_loads_schedule_values = HPXML.get_misc_loads_schedule_values(misc_loads: building.elements["BuildingDetails/MiscLoads"])
      misc_weekday_sch = misc_loads_schedule_values[:weekday_fractions]
      if misc_weekday_sch.nil?
        misc_weekday_sch = "0.04, 0.037, 0.037, 0.036, 0.033, 0.036, 0.043, 0.047, 0.034, 0.023, 0.024, 0.025, 0.024, 0.028, 0.031, 0.032, 0.039, 0.053, 0.063, 0.067, 0.071, 0.069, 0.059, 0.05"
      end

      misc_weekend_sch = misc_loads_schedule_values[:weekend_fractions]
      if misc_weekend_sch.nil?
        misc_weekend_sch = "0.04, 0.037, 0.037, 0.036, 0.033, 0.036, 0.043, 0.047, 0.034, 0.023, 0.024, 0.025, 0.024, 0.028, 0.031, 0.032, 0.039, 0.053, 0.063, 0.067, 0.071, 0.069, 0.059, 0.05"
      end

      misc_monthly_sch = misc_loads_schedule_values[:monthly_multipliers]
      if misc_monthly_sch.nil?
        misc_monthly_sch = "1.248, 1.257, 0.993, 0.989, 0.993, 0.827, 0.821, 0.821, 0.827, 0.99, 0.987, 1.248"
      end
    else
      misc_annual_kwh = 0
    end

    # Television
    plug_load_values = HPXML.get_plug_load_values(plug_load: building.elements["BuildingDetails/MiscLoads/PlugLoad[PlugLoadType='TV other']"])
    if not plug_load_values.nil?
      tv_annual_kwh = plug_load_values[:kWh_per_year]
      if tv_annual_kwh.nil?
        tv_annual_kwh, tv_sens_frac, tv_lat_frac = MiscLoads.get_televisions_values(@cfa, @nbeds)
      end
    else
      tv_annual_kwh = 0
    end

    conditioned_spaces = get_spaces_of_type(spaces, [Constants.SpaceTypeLiving, Constants.SpaceTypeConditionedBasement])
    success, sch = MiscLoads.apply_plug(model, runner, misc_annual_kwh, misc_sens_frac, misc_lat_frac,
                                        misc_weekday_sch, misc_weekend_sch, misc_monthly_sch, tv_annual_kwh,
                                        @cfa, conditioned_spaces)
    return false if not success

    return true
  end

  def self.add_lighting(runner, model, building, weather, spaces)
    lighting = building.elements["BuildingDetails/Lighting"]
    return true if lighting.nil?

    lighting_values = HPXML.get_lighting_values(lighting: lighting)

    if lighting_values[:fraction_tier_i_interior] + lighting_values[:fraction_tier_ii_interior] > 1
      fail "Fraction of qualifying interior lighting fixtures #{lighting_values[:fraction_tier_i_interior] + lighting_values[:fraction_tier_ii_interior]} is greater than 1."
    end
    if lighting_values[:fraction_tier_i_exterior] + lighting_values[:fraction_tier_ii_exterior] > 1
      fail "Fraction of qualifying exterior lighting fixtures #{lighting_values[:fraction_tier_i_exterior] + lighting_values[:fraction_tier_ii_exterior]} is greater than 1."
    end
    if lighting_values[:fraction_tier_i_garage] + lighting_values[:fraction_tier_ii_garage] > 1
      fail "Fraction of qualifying garage lighting fixtures #{lighting_values[:fraction_tier_i_garage] + lighting_values[:fraction_tier_ii_garage]} is greater than 1."
    end

    int_kwh, ext_kwh, grg_kwh = Lighting.calc_lighting_energy(@eri_version, @cfa, @gfa,
                                                              lighting_values[:fraction_tier_i_interior],
                                                              lighting_values[:fraction_tier_i_exterior],
                                                              lighting_values[:fraction_tier_i_garage],
                                                              lighting_values[:fraction_tier_ii_interior],
                                                              lighting_values[:fraction_tier_ii_exterior],
                                                              lighting_values[:fraction_tier_ii_garage])

    conditioned_spaces = get_spaces_of_type(spaces, [Constants.SpaceTypeLiving, Constants.SpaceTypeConditionedBasement])
    garage_spaces = get_spaces_of_type(spaces, [Constants.SpaceTypeGarage])
    success, sch = Lighting.apply(model, runner, weather, int_kwh, grg_kwh, ext_kwh, @cfa, @gfa,
                                  conditioned_spaces, garage_spaces)
    return false if not success

    return true
  end

  def self.add_airflow(runner, model, building, loop_hvacs, spaces)
    # Infiltration
    infil_ach50 = nil
    infil_const_ach = nil
    infil_volume = nil
    building.elements.each("BuildingDetails/Enclosure/AirInfiltration/AirInfiltrationMeasurement") do |air_infiltration_measurement|
      air_infiltration_measurement_values = HPXML.get_air_infiltration_measurement_values(air_infiltration_measurement: air_infiltration_measurement)
      if air_infiltration_measurement_values[:house_pressure] == 50 and air_infiltration_measurement_values[:unit_of_measure] == "ACH"
        infil_ach50 = air_infiltration_measurement_values[:air_leakage]
      else
        infil_const_ach = air_infiltration_measurement_values[:constant_ach_natural]
      end
      # FIXME: Pass infil_volume to infiltration model
      infil_volume = air_infiltration_measurement_values[:infiltration_volume]
      if infil_volume.nil?
        infil_volume = @cvolume
      end
    end

    # Vented crawl SLA
    vented_crawl_area = 0.0
    vented_crawl_sla_area = 0.0
    building.elements.each("BuildingDetails/Enclosure/Foundations/Foundation[FoundationType/Crawlspace[Vented='true']]") do |vented_crawl|
      foundation_values = HPXML.get_foundation_values(foundation: vented_crawl)
      frame_floor_values = HPXML.get_foundation_framefloor_values(floor: vented_crawl.elements["FrameFloor"])
      area = frame_floor_values[:area]
      vented_crawl_sla_area += (foundation_values[:specific_leakage_area] * area)
      vented_crawl_area += area
    end
    if vented_crawl_area > 0
      crawl_sla = vented_crawl_sla_area / vented_crawl_area
    else
      crawl_sla = 0.0
    end

    # Vented attic SLA
    vented_attic_area = 0.0
    vented_attic_sla_area = 0.0
    vented_attic_const_ach = nil
    building.elements.each("BuildingDetails/Enclosure/Attics/Attic[AtticType/Attic[Vented='true']]") do |vented_attic|
      attic_values = HPXML.get_attic_values(attic: vented_attic)
      attic_floor_values = HPXML.get_attic_floor_values(floor: vented_attic.elements["Floors/Floor"])
      area = attic_floor_values[:area]
      vented_attic_const_ach = attic_values[:constant_ach_natural]
      if not attic_values[:specific_leakage_area].nil?
        vented_attic_sla_area += (attic_values[:specific_leakage_area] * area)
      end
      vented_attic_area += area
    end
    if not vented_attic_const_ach.nil?
      attic_sla = nil
      attic_const_ach = vented_attic_const_ach
    elsif vented_attic_sla_area > 0
      attic_sla = vented_attic_sla_area / vented_attic_area
      attic_const_ach = nil
    else
      attic_sla = 0
      attic_const_ach = nil
    end

    living_ach50 = infil_ach50
    living_constant_ach = infil_const_ach
    garage_ach50 = infil_ach50
    conditioned_basement_ach = 0 # TODO: Need to handle above-grade basement
    unconditioned_basement_ach = 0.1 # TODO: Need to handle above-grade basement
    crawl_ach = crawl_sla # FIXME: sla vs ach
    pier_beam_ach = 100
    site_values = HPXML.get_site_values(site: building.elements["BuildingDetails/BuildingSummary/Site"])
    shelter_coef = site_values[:shelter_coefficient]
    if shelter_coef.nil?
      shelter_coef = Airflow.get_default_shelter_coefficient()
    end
    has_flue_chimney = false
    is_existing_home = false
    terrain = Constants.TerrainSuburban
    infil = Infiltration.new(living_ach50, living_constant_ach, shelter_coef, garage_ach50, crawl_ach, attic_sla, attic_const_ach, unconditioned_basement_ach,
                             conditioned_basement_ach, pier_beam_ach, has_flue_chimney, is_existing_home, terrain)

    # Mechanical Ventilation
    whole_house_fan = building.elements["BuildingDetails/Systems/MechanicalVentilation/VentilationFans/VentilationFan[UsedForWholeBuildingVentilation='true']"]
    whole_house_fan_values = HPXML.get_ventilation_fan_values(ventilation_fan: whole_house_fan)
    mech_vent_type = Constants.VentTypeNone
    mech_vent_total_efficiency = 0.0
    mech_vent_sensible_efficiency = 0.0
    mech_vent_fan_w = 0.0
    mech_vent_cfm = 0.0
    cfis_open_time = 0.0
    if not whole_house_fan_values.nil?
      fan_type = whole_house_fan_values[:fan_type]
      if fan_type == "supply only"
        mech_vent_type = Constants.VentTypeSupply
        num_fans = 1.0
      elsif fan_type == "exhaust only"
        mech_vent_type = Constants.VentTypeExhaust
        num_fans = 1.0
      elsif fan_type == "central fan integrated supply"
        mech_vent_type = Constants.VentTypeCFIS
        num_fans = 1.0
      elsif ["balanced", "energy recovery ventilator", "heat recovery ventilator"].include? fan_type
        mech_vent_type = Constants.VentTypeBalanced
        num_fans = 2.0
      end
      mech_vent_total_efficiency = 0.0
      mech_vent_sensible_efficiency = 0.0
      if fan_type == "energy recovery ventilator" or fan_type == "heat recovery ventilator"
        mech_vent_sensible_efficiency = whole_house_fan_values[:sensible_recovery_efficiency]
      end
      if fan_type == "energy recovery ventilator"
        mech_vent_total_efficiency = whole_house_fan_values[:total_recovery_efficiency]
      end
      mech_vent_cfm = whole_house_fan_values[:rated_flow_rate]
      mech_vent_fan_w = whole_house_fan_values[:fan_power]
      if mech_vent_type == Constants.VentTypeCFIS
        # CFIS: Specify minimum open time in minutes
        cfis_open_time = whole_house_fan_values[:hours_in_operation] / 24.0 * 60.0
      else
        # Other: Adjust CFM based on hours/day of operation
        mech_vent_cfm *= (whole_house_fan_values[:hours_in_operation] / 24.0)
      end
    end
    cfis_airflow_frac = 1.0
    clothes_dryer_exhaust = 0.0
    range_exhaust = 0.0
    range_exhaust_hour = 16
    bathroom_exhaust = 0.0
    bathroom_exhaust_hour = 5

    # Get AirLoops associated with CFIS
    cfis_airloops = []
    if mech_vent_type == Constants.VentTypeCFIS
      # Get HVAC distribution system CFIS is attached to
      cfis_hvac_dist = nil
      building.elements.each("BuildingDetails/Systems/HVAC/HVACDistribution") do |hvac_dist|
        next unless hvac_dist.elements["SystemIdentifier"].attributes["id"] == whole_house_fan.elements["AttachedToHVACDistributionSystem"].attributes["idref"]

        cfis_hvac_dist = hvac_dist
      end
      if cfis_hvac_dist.nil?
        fail "Attached HVAC distribution system '#{whole_house_fan.elements['AttachedToHVACDistributionSystem'].attributes['idref']}' not found for mechanical ventilation '#{whole_house_fan.elements["SystemIdentifier"].attributes["id"]}'."
      end

      cfis_hvac_dist_values = HPXML.get_hvac_distribution_values(hvac_distribution: cfis_hvac_dist)
      if cfis_hvac_dist_values[:distribution_system_type] == 'HydronicDistribution'
        fail "Attached HVAC distribution system '#{whole_house_fan.elements['AttachedToHVACDistributionSystem'].attributes['idref']}' cannot be hydronic for mechanical ventilation '#{whole_house_fan.elements["SystemIdentifier"].attributes["id"]}'."
      end

      # Get HVAC systems attached to this distribution system
      cfis_sys_ids = []
      hvac_plant = building.elements["BuildingDetails/Systems/HVAC/HVACPlant"]
      hvac_plant.elements.each("HeatingSystem | CoolingSystem | HeatPump") do |hvac|
        next unless XMLHelper.has_element(hvac, "DistributionSystem")
        next unless cfis_hvac_dist.elements["SystemIdentifier"].attributes["id"] == hvac.elements["DistributionSystem"].attributes["idref"]

        cfis_sys_ids << hvac.elements["SystemIdentifier"].attributes["id"]
      end

      # Get AirLoopHVACs associated with these HVAC systems
      loop_hvacs.each do |sys_id, loops|
        next unless cfis_sys_ids.include? sys_id

        loops.each do |loop|
          next unless loop.is_a? OpenStudio::Model::AirLoopHVAC

          cfis_airloops << loop
        end
      end
    end

    mech_vent = MechanicalVentilation.new(mech_vent_type, nil, mech_vent_total_efficiency,
                                          nil, mech_vent_cfm, mech_vent_fan_w, mech_vent_sensible_efficiency,
                                          nil, clothes_dryer_exhaust, range_exhaust,
                                          range_exhaust_hour, bathroom_exhaust, bathroom_exhaust_hour,
                                          cfis_open_time, cfis_airflow_frac, cfis_airloops)

    # Natural Ventilation
    site_values = HPXML.get_site_values(site: building.elements["BuildingDetails/BuildingSummary/Site"])
    disable_nat_vent = site_values[:disable_natural_ventilation]
    if not disable_nat_vent.nil? and disable_nat_vent
      nat_vent_htg_offset = 0
      nat_vent_clg_offset = 0
      nat_vent_ovlp_offset = 0
      nat_vent_htg_season = false
      nat_vent_clg_season = false
      nat_vent_ovlp_season = false
      nat_vent_num_weekdays = 0
      nat_vent_num_weekends = 0
      nat_vent_frac_windows_open = 0
      nat_vent_frac_window_area_openable = 0
      nat_vent_max_oa_hr = 0.0115
      nat_vent_max_oa_rh = 0.7
    else
      nat_vent_htg_offset = 1.0
      nat_vent_clg_offset = 1.0
      nat_vent_ovlp_offset = 1.0
      nat_vent_htg_season = true
      nat_vent_clg_season = true
      nat_vent_ovlp_season = true
      nat_vent_num_weekdays = 5
      nat_vent_num_weekends = 2
      nat_vent_frac_windows_open = 0.33
      nat_vent_frac_window_area_openable = 0.2
      nat_vent_max_oa_hr = 0.0115
      nat_vent_max_oa_rh = 0.7
    end
    nat_vent = NaturalVentilation.new(nat_vent_htg_offset, nat_vent_clg_offset, nat_vent_ovlp_offset, nat_vent_htg_season,
                                      nat_vent_clg_season, nat_vent_ovlp_season, nat_vent_num_weekdays,
                                      nat_vent_num_weekends, nat_vent_frac_windows_open, nat_vent_frac_window_area_openable,
                                      nat_vent_max_oa_hr, nat_vent_max_oa_rh)

    # Ducts
    duct_systems = {}
    side_map = { 'supply' => Constants.DuctSideSupply,
                 'return' => Constants.DuctSideReturn }
    building.elements.each("BuildingDetails/Systems/HVAC/HVACDistribution") do |hvac_distribution|
      hvac_distribution_values = HPXML.get_hvac_distribution_values(hvac_distribution: hvac_distribution)
      air_distribution = hvac_distribution.elements["DistributionSystemType/AirDistribution"]
      next if air_distribution.nil?

      air_ducts = []

      # Duct leakage
      leakage_to_outside_cfm25 = { Constants.DuctSideSupply => 0.0,
                                   Constants.DuctSideReturn => 0.0 }
      air_distribution.elements.each("DuctLeakageMeasurement") do |duct_leakage_measurement|
        duct_leakage_values = HPXML.get_duct_leakage_measurement_values(duct_leakage_measurement: duct_leakage_measurement)
        next unless duct_leakage_values[:duct_leakage_units] == "CFM25" and duct_leakage_values[:duct_leakage_total_or_to_outside] == "to outside"

        duct_side = side_map[duct_leakage_values[:duct_type]]
        leakage_to_outside_cfm25[duct_side] = duct_leakage_values[:duct_leakage_value]
      end

      # Duct location, Rvalue, Area
      total_duct_area = { Constants.DuctSideSupply => 0.0,
                          Constants.DuctSideReturn => 0.0 }
      air_distribution.elements.each("Ducts") do |ducts|
        ducts_values = HPXML.get_ducts_values(ducts: ducts)
        next if ['living space', 'basement - conditioned', 'attic - conditioned'].include? ducts_values[:duct_location]

        # Calculate total duct area in unconditioned spaces
        duct_side = side_map[ducts_values[:duct_type]]
        total_duct_area[duct_side] += ducts_values[:duct_surface_area]
      end

      air_distribution.elements.each("Ducts") do |ducts|
        ducts_values = HPXML.get_ducts_values(ducts: ducts)
        next if ['living space', 'basement - conditioned', 'attic - conditioned'].include? ducts_values[:duct_location]

        duct_side = side_map[ducts_values[:duct_type]]
        duct_area = ducts_values[:duct_surface_area]
        duct_space = get_space_from_location(ducts_values[:duct_location], "Duct", model, spaces)
        # Apportion leakage to individual ducts by surface area
        duct_leakage_cfm = (leakage_to_outside_cfm25[duct_side] *
                            duct_area / total_duct_area[duct_side])

        air_ducts << Duct.new(duct_side, duct_space, nil, duct_leakage_cfm, duct_area, ducts_values[:duct_insulation_r_value])
      end

      # Connect AirLoopHVACs to ducts
      systems_for_this_duct = []
      dist_id = hvac_distribution_values[:id]
      heating_systems_attached = []
      cooling_systems_attached = []
      ['HeatingSystem', 'CoolingSystem', 'HeatPump'].each do |hpxml_sys|
        building.elements.each("BuildingDetails/Systems/HVAC/HVACPlant/#{hpxml_sys}") do |sys|
          next if sys.elements["DistributionSystem"].nil? or dist_id != sys.elements["DistributionSystem"].attributes["idref"]

          sys_id = sys.elements["SystemIdentifier"].attributes["id"]
          heating_systems_attached << sys_id if ['HeatingSystem', 'HeatPump'].include? hpxml_sys
          cooling_systems_attached << sys_id if ['CoolingSystem', 'HeatPump'].include? hpxml_sys

          next if loop_hvacs[sys_id].nil?

          loop_hvacs[sys_id].each do |loop|
            next unless loop.is_a? OpenStudio::Model::AirLoopHVAC

            systems_for_this_duct << loop
          end
        end

        duct_systems[air_ducts] = systems_for_this_duct
      end

      fail "Multiple cooling systems found attached to distribution system '#{dist_id}'." if cooling_systems_attached.size > 1
      fail "Multiple heating systems found attached to distribution system '#{dist_id}'." if heating_systems_attached.size > 1
    end

    window_area = 0.0
    building.elements.each("BuildingDetails/Enclosure/Windows/Window") do |window|
      window_values = HPXML.get_window_values(window: window)
      window_area += window_values[:area]
    end

    success = Airflow.apply(model, runner, infil, mech_vent, nat_vent, duct_systems,
                            @cfa, @cfa_ag, @nbeds, @nbaths, @ncfl, @ncfl_ag, window_area,
                            @min_neighbor_distance)
    return false if not success

    return true
  end

  def self.add_hvac_sizing(runner, model, weather)
    success = HVACSizing.apply(model, runner, weather, @cfa, @nbeds, @min_neighbor_distance, false)
    return false if not success

    return true
  end

  def self.add_fuel_heating_eae(runner, model, building, loop_hvacs, zone_hvacs)
    # Needs to come after HVAC sizing (needs heating capacity and airflow rate)
    # FUTURE: Could remove this method and simplify everything if we could autosize via the HPXML file

    building.elements.each("BuildingDetails/Systems/HVAC/HVACPlant/HeatingSystem[FractionHeatLoadServed > 0]") do |htgsys|
      heating_system_values = HPXML.get_heating_system_values(heating_system: htgsys)
      htg_type = heating_system_values[:heating_system_type]
      next unless ["Furnace", "WallFurnace", "Stove", "Boiler"].include? htg_type

      fuel = to_beopt_fuel(heating_system_values[:heating_system_fuel])
      next if fuel == Constants.FuelTypeElectric

      fuel_eae = heating_system_values[:electric_auxiliary_energy]

      load_frac = heating_system_values[:fraction_heat_load_served]

      dse_heat, dse_cool, has_dse = get_dse(building, heating_system_values)

      sys_id = heating_system_values[:id]

      eae_loop_hvac = nil
      eae_zone_hvacs = nil
      eae_loop_hvac_cool = nil
      if loop_hvacs.keys.include? sys_id
        eae_loop_hvac = loop_hvacs[sys_id][0]
        has_furnace = (htg_type == "Furnace")
        has_boiler = (htg_type == "Boiler")

        if has_furnace
          # Check for cooling system on the same supply fan
          htgdist = htgsys.elements["DistributionSystem"]
          building.elements.each("BuildingDetails/Systems/HVAC/HVACPlant/CoolingSystem[FractionCoolLoadServed > 0]") do |clgsys|
            cooling_system_values = HPXML.get_cooling_system_values(cooling_system: clgsys)
            clgdist = clgsys.elements["DistributionSystem"]
            next if htgdist.nil? or clgdist.nil?
            next if cooling_system_values[:distribution_system_idref] != heating_system_values[:distribution_system_idref]

            eae_loop_hvac_cool = loop_hvacs[cooling_system_values[:id]][0]
          end
        end
      elsif zone_hvacs.keys.include? sys_id
        eae_zone_hvacs = zone_hvacs[sys_id]
      end

      success = HVAC.apply_eae_to_heating_fan(runner, eae_loop_hvac, eae_zone_hvacs, fuel_eae, fuel, dse_heat,
                                              has_furnace, has_boiler, load_frac, eae_loop_hvac_cool)
      return false if not success
    end

    return true
  end

  def self.add_photovoltaics(runner, model, building)
    pv_system_values = HPXML.get_pv_system_values(pv_system: building.elements["BuildingDetails/Systems/Photovoltaics/PVSystem"])
    return true if pv_system_values.nil?

    modules_map = { "standard" => Constants.PVModuleTypeStandard,
                    "premium" => Constants.PVModuleTypePremium,
                    "thin film" => Constants.PVModuleTypeThinFilm }

    building.elements.each("BuildingDetails/Systems/Photovoltaics/PVSystem") do |pvsys|
      pv_system_values = HPXML.get_pv_system_values(pv_system: pvsys)
      pv_id = pv_system_values[:id]
      module_type = modules_map[pv_system_values[:module_type]]
      if pv_system_values[:tracking] == 'fixed' and pv_system_values[:location] == 'roof'
        array_type = Constants.PVArrayTypeFixedRoofMount
      elsif pv_system_values[:tracking] == 'fixed' and pv_system_values[:location] == 'ground'
        array_type = Constants.PVArrayTypeFixedOpenRack
      elsif pv_system_values[:tracking] == '1-axis'
        array_type = Constants.PVArrayTypeFixed1Axis
      elsif pv_system_values[:tracking] == '1-axis backtracked'
        array_type = Constants.PVArrayTypeFixed1AxisBacktracked
      elsif pv_system_values[:tracking] == '2-axis'
        array_type = Constants.PVArrayTypeFixed2Axis
      end
      az = pv_system_values[:array_azimuth]
      tilt = pv_system_values[:array_tilt]
      power_w = pv_system_values[:max_power_output]
      inv_eff = pv_system_values[:inverter_efficiency]
      system_losses = pv_system_values[:system_losses_fraction]

      success = PV.apply(model, runner, pv_id, power_w, module_type,
                         system_losses, inv_eff, tilt, az, array_type)
      return false if not success
    end

    return true
  end

  def self.add_building_output_variables(runner, model, loop_hvacs, zone_hvacs, loop_dhws, map_tsv_dir)
    htg_mapping = {}
    clg_mapping = {}
    dhw_mapping = {}

    # AirLoopHVAC systems
    loop_hvacs.each do |sys_id, loops|
      htg_mapping[sys_id] = []
      clg_mapping[sys_id] = []
      loops.each do |loop|
        next unless loop.is_a? OpenStudio::Model::AirLoopHVAC

        unitary_system = HVAC.get_unitary_system_from_air_loop_hvac(loop)

        if unitary_system.coolingCoil.is_initialized
          # Cooling system: Cooling coil, supply fan
          clg_mapping[sys_id] << HVAC.get_coil_from_hvac_component(unitary_system.coolingCoil.get)
          clg_mapping[sys_id] << unitary_system.supplyFan.get.to_FanOnOff.get
        elsif unitary_system.heatingCoil.is_initialized
          # Heating system: Heating coil, supply fan, supplemental coil
          htg_mapping[sys_id] << HVAC.get_coil_from_hvac_component(unitary_system.heatingCoil.get)
          htg_mapping[sys_id] << unitary_system.supplyFan.get.to_FanOnOff.get
          if unitary_system.supplementalHeatingCoil.is_initialized
            htg_mapping[sys_id] << HVAC.get_coil_from_hvac_component(unitary_system.supplementalHeatingCoil.get)
          end
        end
      end
    end

    zone_hvacs.each do |sys_id, hvacs|
      htg_mapping[sys_id] = []
      clg_mapping[sys_id] = []
      hvacs.each do |hvac|
        next unless hvac.to_ZoneHVACComponent.is_initialized

        if hvac.to_AirLoopHVACUnitarySystem.is_initialized

          unitary_system = hvac.to_AirLoopHVACUnitarySystem.get
          if unitary_system.coolingCoil.is_initialized
            # Cooling system: Cooling coil, supply fan
            clg_mapping[sys_id] << HVAC.get_coil_from_hvac_component(unitary_system.coolingCoil.get)
            clg_mapping[sys_id] << unitary_system.supplyFan.get.to_FanOnOff.get
          elsif unitary_system.heatingCoil.is_initialized
            # Heating system: Heating coil, supply fan
            htg_mapping[sys_id] << HVAC.get_coil_from_hvac_component(unitary_system.heatingCoil.get)
            htg_mapping[sys_id] << unitary_system.supplyFan.get.to_FanOnOff.get
          end

        elsif hvac.to_ZoneHVACPackagedTerminalAirConditioner.is_initialized

          ptac = hvac.to_ZoneHVACPackagedTerminalAirConditioner.get
          clg_mapping[sys_id] << HVAC.get_coil_from_hvac_component(ptac.coolingCoil)

        elsif hvac.to_ZoneHVACBaseboardConvectiveElectric.is_initialized

          htg_mapping[sys_id] << hvac.to_ZoneHVACBaseboardConvectiveElectric.get

        elsif hvac.to_ZoneHVACBaseboardConvectiveWater.is_initialized

          baseboard = hvac.to_ZoneHVACBaseboardConvectiveWater.get
          baseboard.heatingCoil.plantLoop.get.components.each do |comp|
            next unless comp.to_BoilerHotWater.is_initialized

            htg_mapping[sys_id] << comp.to_BoilerHotWater.get
          end

        end
      end
    end

    loop_dhws.each do |sys_id, loops|
      dhw_mapping[sys_id] = []
      loops.each do |loop|
        loop.supplyComponents.each do |comp|
          if comp.to_WaterHeaterMixed.is_initialized

            water_heater = comp.to_WaterHeaterMixed.get
            dhw_mapping[sys_id] << water_heater

          elsif comp.to_WaterHeaterStratified.is_initialized

            hpwh_tank = comp.to_WaterHeaterStratified.get
            dhw_mapping[sys_id] << hpwh_tank

            model.getWaterHeaterHeatPumpWrappedCondensers.each do |hpwh|
              next if hpwh.tank.name.to_s != hpwh_tank.name.to_s

              water_heater_coil = hpwh.dXCoil.to_CoilWaterHeatingAirToWaterHeatPumpWrapped.get
              dhw_mapping[sys_id] << water_heater_coil
            end

          end
        end

        recirc_pump_name = loop.additionalProperties.getFeatureAsString("PlantLoopRecircPump")
        if recirc_pump_name.is_initialized
          recirc_pump_name = recirc_pump_name.get
          model.getElectricEquipments.each do |ee|
            next unless ee.name.to_s == recirc_pump_name

            dhw_mapping[sys_id] << ee
          end
        end

        loop.demandComponents.each do |comp|
          if comp.to_WaterUseConnections.is_initialized

            water_use_connections = comp.to_WaterUseConnections.get
            dhw_mapping[sys_id] << water_use_connections

          end
        end
      end
    end

    htg_mapping.each do |sys_id, htg_equip_list|
      add_output_variables(model, OutputVars.SpaceHeatingElectricity, htg_equip_list)
      add_output_variables(model, OutputVars.SpaceHeatingFuel, htg_equip_list)
      add_output_variables(model, OutputVars.SpaceHeatingLoad, htg_equip_list)
    end
    clg_mapping.each do |sys_id, clg_equip_list|
      add_output_variables(model, OutputVars.SpaceCoolingElectricity, clg_equip_list)
      add_output_variables(model, OutputVars.SpaceCoolingLoad, clg_equip_list)
    end
    dhw_mapping.each do |sys_id, dhw_equip_list|
      add_output_variables(model, OutputVars.WaterHeatingElectricity, dhw_equip_list)
      add_output_variables(model, OutputVars.WaterHeatingElectricityRecircPump, dhw_equip_list)
      add_output_variables(model, OutputVars.WaterHeatingFuel, dhw_equip_list)
      add_output_variables(model, OutputVars.WaterHeatingLoad, dhw_equip_list)
    end

    if map_tsv_dir.is_initialized
      map_tsv_dir = map_tsv_dir.get
      write_mapping(htg_mapping, File.join(map_tsv_dir, "map_hvac_heating.tsv"))
      write_mapping(clg_mapping, File.join(map_tsv_dir, "map_hvac_cooling.tsv"))
      write_mapping(dhw_mapping, File.join(map_tsv_dir, "map_water_heating.tsv"))
    end

    return true
  end

  def self.add_output_variables(model, vars, objects)
    if objects.nil?
      vars[nil].each do |object_var|
        outputVariable = OpenStudio::Model::OutputVariable.new(object_var, model)
        outputVariable.setReportingFrequency('runperiod')
        outputVariable.setKeyValue('*')
      end
    else
      objects.each do |object|
        if vars[object.class.to_s].nil?
          fail "Unexpected object type #{object.class.to_s}."
        end

        vars[object.class.to_s].each do |object_var|
          outputVariable = OpenStudio::Model::OutputVariable.new(object_var, model)
          outputVariable.setReportingFrequency('runperiod')
          outputVariable.setKeyValue(object.name.to_s)
        end
      end
    end
  end

  def self.write_mapping(mapping, map_tsv_path)
    # Write simple mapping TSV file for use by ERI calculation. Mapping file correlates
    # EnergyPlus object name to a HPXML object name.

    CSV.open(map_tsv_path, 'w', col_sep: "\t") do |tsv|
      # Header
      tsv << ["HPXML Name", "E+ Name(s)"]

      mapping.each do |sys_id, objects|
        out_data = [sys_id]
        objects.each do |object|
          out_data << object.name.to_s
        end
        tsv << out_data if out_data.size > 1
      end
    end
  end

  def self.calc_non_cavity_r(film_r, constr_set)
    # Calculate R-value for all non-cavity layers
    non_cavity_r = film_r
    if not constr_set.exterior_material.nil?
      non_cavity_r += constr_set.exterior_material.rvalue
    end
    if not constr_set.rigid_r.nil?
      non_cavity_r += constr_set.rigid_r
    end
    if not constr_set.osb_thick_in.nil?
      non_cavity_r += Material.Plywood(constr_set.osb_thick_in).rvalue
    end
    if not constr_set.drywall_thick_in.nil?
      non_cavity_r += Material.GypsumWall(constr_set.drywall_thick_in).rvalue
    end
    return non_cavity_r
  end

  def self.apply_wall_construction(runner, model, surface, wall_id, wall_type, assembly_r,
                                   drywall_thick_in, film_r, mat_ext_finish, solar_abs, emitt)
    if wall_type == "WoodStud"
      install_grade = 1
      cavity_filled = true

      constr_sets = [
        WoodStudConstructionSet.new(Material.Stud2x6, 0.20, 10.0, 0.5, drywall_thick_in, mat_ext_finish), # 2x6, 24" o.c. + R10
        WoodStudConstructionSet.new(Material.Stud2x6, 0.20, 5.0, 0.5, drywall_thick_in, mat_ext_finish),  # 2x6, 24" o.c. + R5
        WoodStudConstructionSet.new(Material.Stud2x6, 0.20, 0.0, 0.5, drywall_thick_in, mat_ext_finish),  # 2x6, 24" o.c.
        WoodStudConstructionSet.new(Material.Stud2x4, 0.23, 0.0, 0.5, drywall_thick_in, mat_ext_finish),  # 2x4, 16" o.c.
        WoodStudConstructionSet.new(Material.Stud2x4, 0.01, 0.0, 0.0, 0.0, nil),                          # Fallback
      ]
      constr_set, cavity_r = pick_wood_stud_construction_set(assembly_r, constr_sets, film_r, "wall #{wall_id}")

      success = Constructions.apply_wood_stud_wall(runner, model, [surface], "WallConstruction",
                                                   cavity_r, install_grade, constr_set.stud.thick_in,
                                                   cavity_filled, constr_set.framing_factor,
                                                   constr_set.drywall_thick_in, constr_set.osb_thick_in,
                                                   constr_set.rigid_r, constr_set.exterior_material)
      return false if not success

    elsif wall_type == "SteelFrame"
      install_grade = 1
      cavity_filled = true
      corr_factor = 0.45

      constr_sets = [
        SteelStudConstructionSet.new(5.5, corr_factor, 0.20, 10.0, 0.5, drywall_thick_in, mat_ext_finish), # 2x6, 24" o.c. + R10
        SteelStudConstructionSet.new(5.5, corr_factor, 0.20, 5.0, 0.5, drywall_thick_in, mat_ext_finish),  # 2x6, 24" o.c. + R5
        SteelStudConstructionSet.new(5.5, corr_factor, 0.20, 0.0, 0.5, drywall_thick_in, mat_ext_finish),  # 2x6, 24" o.c.
        SteelStudConstructionSet.new(3.5, corr_factor, 0.23, 0.0, 0.5, drywall_thick_in, mat_ext_finish),  # 2x4, 16" o.c.
        SteelStudConstructionSet.new(3.5, 1.0, 0.01, 0.0, 0.0, 0.0, nil),                                  # Fallback
      ]
      constr_set, cavity_r = pick_steel_stud_construction_set(assembly_r, constr_sets, film_r, "wall #{wall_id}")

      success = Constructions.apply_steel_stud_wall(runner, model, [surface], "WallConstruction",
                                                    cavity_r, install_grade, constr_set.cavity_thick_in,
                                                    cavity_filled, constr_set.framing_factor,
                                                    constr_set.corr_factor, constr_set.drywall_thick_in,
                                                    constr_set.osb_thick_in, constr_set.rigid_r,
                                                    constr_set.exterior_material)
      return false if not success

    elsif wall_type == "DoubleWoodStud"
      install_grade = 1
      is_staggered = false

      constr_sets = [
        DoubleStudConstructionSet.new(Material.Stud2x4, 0.23, 24.0, 0.0, 0.5, drywall_thick_in, mat_ext_finish),  # 2x4, 24" o.c.
        DoubleStudConstructionSet.new(Material.Stud2x4, 0.01, 16.0, 0.0, 0.0, 0.0, nil),                          # Fallback
      ]
      constr_set, cavity_r = pick_double_stud_construction_set(assembly_r, constr_sets, film_r, "wall #{wall_id}")

      success = Constructions.apply_double_stud_wall(runner, model, [surface], "WallConstruction",
                                                     cavity_r, install_grade, constr_set.stud.thick_in,
                                                     constr_set.stud.thick_in, constr_set.framing_factor,
                                                     constr_set.framing_spacing, is_staggered,
                                                     constr_set.drywall_thick_in, constr_set.osb_thick_in,
                                                     constr_set.rigid_r, constr_set.exterior_material)
      return false if not success

    elsif wall_type == "ConcreteMasonryUnit"
      density = 119.0 # lb/ft^3
      furring_r = 0
      furring_cavity_depth_in = 0 # in
      furring_spacing = 0

      constr_sets = [
        CMUConstructionSet.new(8.0, 1.4, 0.08, 0.5, drywall_thick_in, mat_ext_finish),  # 8" perlite-filled CMU
        CMUConstructionSet.new(6.0, 5.29, 0.01, 0.0, 0.0, nil),                         # Fallback (6" hollow CMU)
      ]
      constr_set, rigid_r = pick_cmu_construction_set(assembly_r, constr_sets, film_r, "wall #{wall_id}")

      success = Constructions.apply_cmu_wall(runner, model, [surface], "WallConstruction",
                                             constr_set.thick_in, constr_set.cond_in, density,
                                             constr_set.framing_factor, furring_r,
                                             furring_cavity_depth_in, furring_spacing,
                                             constr_set.drywall_thick_in, constr_set.osb_thick_in,
                                             rigid_r, constr_set.exterior_material)
      return false if not success

    elsif wall_type == "StructurallyInsulatedPanel"
      sheathing_thick_in = 0.44
      sheathing_type = Constants.MaterialOSB

      constr_sets = [
        SIPConstructionSet.new(10.0, 0.16, 0.0, sheathing_thick_in, 0.5, drywall_thick_in, mat_ext_finish), # 10" SIP core
        SIPConstructionSet.new(5.0, 0.16, 0.0, sheathing_thick_in, 0.5, drywall_thick_in, mat_ext_finish),  # 5" SIP core
        SIPConstructionSet.new(1.0, 0.01, 0.0, sheathing_thick_in, 0.0, 0.0, nil),                          # Fallback
      ]
      constr_set, cavity_r = pick_sip_construction_set(assembly_r, constr_sets, film_r, "wall #{wall_id}")

      success = Constructions.apply_sip_wall(runner, model, [surface], "WallConstruction",
                                             cavity_r, constr_set.thick_in, constr_set.framing_factor,
                                             sheathing_type, constr_set.sheath_thick_in,
                                             constr_set.drywall_thick_in, constr_set.osb_thick_in,
                                             constr_set.rigid_r, constr_set.exterior_material)
      return false if not success

    elsif wall_type == "InsulatedConcreteForms"
      constr_sets = [
        ICFConstructionSet.new(2.0, 4.0, 0.08, 0.0, 0.5, drywall_thick_in, mat_ext_finish), # ICF w/4" concrete and 2" rigid ins layers
        ICFConstructionSet.new(1.0, 1.0, 0.01, 0.0, 0.0, 0.0, nil),                         # Fallback
      ]
      constr_set, icf_r = pick_icf_construction_set(assembly_r, constr_sets, film_r, "wall #{wall_id}")

      success = Constructions.apply_icf_wall(runner, model, [surface], "WallConstruction",
                                             icf_r, constr_set.ins_thick_in,
                                             constr_set.concrete_thick_in, constr_set.framing_factor,
                                             constr_set.drywall_thick_in, constr_set.osb_thick_in,
                                             constr_set.rigid_r, constr_set.exterior_material)
      return false if not success

    elsif ["SolidConcrete", "StructuralBrick", "StrawBale", "Stone", "LogWall"].include? wall_type
      constr_sets = [
        GenericConstructionSet.new(10.0, 0.5, drywall_thick_in, mat_ext_finish), # w/R-10 rigid
        GenericConstructionSet.new(0.0, 0.5, drywall_thick_in, mat_ext_finish),  # Standard
        GenericConstructionSet.new(0.0, 0.0, 0.0, nil),                          # Fallback
      ]
      constr_set, layer_r = pick_generic_construction_set(assembly_r, constr_sets, film_r, "wall #{wall_id}")

      if wall_type == "SolidConcrete"
        thick_in = 6.0
        base_mat = BaseMaterial.Concrete
      elsif wall_type == "StructuralBrick"
        thick_in = 8.0
        base_mat = BaseMaterial.Brick
      elsif wall_type == "StrawBale"
        thick_in = 23.0
        base_mat = BaseMaterial.StrawBale
      elsif wall_type == "Stone"
        thick_in = 6.0
        base_mat = BaseMaterial.Stone
      elsif wall_type == "LogWall"
        thick_in = 6.0
        base_mat = BaseMaterial.Wood
      end
      thick_ins = [thick_in]
      conds = [thick_in / layer_r]
      denss = [base_mat.rho]
      specheats = [base_mat.cp]

      success = Constructions.apply_generic_layered_wall(runner, model, [surface], "WallConstruction",
                                                         thick_ins, conds, denss, specheats,
                                                         constr_set.drywall_thick_in, constr_set.osb_thick_in,
                                                         constr_set.rigid_r, constr_set.exterior_material)
      return false if not success

    else

      fail "Unexpected wall type '#{wall_type}'."

    end

    check_surface_assembly_rvalue(surface, film_r, assembly_r)

    apply_solar_abs_emittance_to_construction(surface, solar_abs, emitt)
  end

  def self.pick_wood_stud_construction_set(assembly_r, constr_sets, film_r, surface_name)
    # Picks a construction set from supplied constr_sets for which a positive R-value
    # can be calculated for the unknown insulation to achieve the assembly R-value.

    constr_sets.each do |constr_set|
      fail "Unexpected object." unless constr_set.is_a? WoodStudConstructionSet

      non_cavity_r = calc_non_cavity_r(film_r, constr_set)

      # Calculate effective cavity R-value
      # Assumes installation quality 1
      cavity_frac = 1.0 - constr_set.framing_factor
      cavity_r = cavity_frac / (1.0 / assembly_r - constr_set.framing_factor / (constr_set.stud.rvalue + non_cavity_r)) - non_cavity_r
      if cavity_r > 0 # Choose this construction set
        return constr_set, cavity_r
      end
    end

    fail "Unable to calculate a construction for '#{surface_name}' using the provided assembly R-value (#{assembly_r})."
  end

  def self.pick_steel_stud_construction_set(assembly_r, constr_sets, film_r, surface_name)
    # Picks a construction set from supplied constr_sets for which a positive R-value
    # can be calculated for the unknown insulation to achieve the assembly R-value.

    constr_sets.each do |constr_set|
      fail "Unexpected object." unless constr_set.is_a? SteelStudConstructionSet

      non_cavity_r = calc_non_cavity_r(film_r, constr_set)

      # Calculate effective cavity R-value
      # Assumes installation quality 1
      cavity_r = (assembly_r - non_cavity_r) / constr_set.corr_factor
      if cavity_r > 0 # Choose this construction set
        return constr_set, cavity_r
      end
    end

    fail "Unable to calculate a construction for '#{surface_name}' using the provided assembly R-value (#{assembly_r})."
  end

  def self.pick_double_stud_construction_set(assembly_r, constr_sets, film_r, surface_name)
    # Picks a construction set from supplied constr_sets for which a positive R-value
    # can be calculated for the unknown insulation to achieve the assembly R-value.

    constr_sets.each do |constr_set|
      fail "Unexpected object." unless constr_set.is_a? DoubleStudConstructionSet

      non_cavity_r = calc_non_cavity_r(film_r, constr_set)

      # Calculate effective cavity R-value
      # Assumes installation quality 1, not staggered, gap depth == stud depth
      # Solved in Wolfram Alpha: https://www.wolframalpha.com/input/?i=1%2FA+%3D+B%2F(2*C%2Bx%2BD)+%2B+E%2F(3*C%2BD)+%2B+(1-B-E)%2F(3*x%2BD)
      stud_frac = 1.5 / constr_set.framing_spacing
      misc_framing_factor = constr_set.framing_factor - stud_frac
      cavity_frac = 1.0 - (2 * stud_frac + misc_framing_factor)
      a = assembly_r
      b = stud_frac
      c = constr_set.stud.rvalue
      d = non_cavity_r
      e = misc_framing_factor
      cavity_r = ((3 * c + d) * Math.sqrt(4 * a**2 * b**2 + 12 * a**2 * b * e + 4 * a**2 * b + 9 * a**2 * e**2 - 6 * a**2 * e + a**2 - 48 * a * b * c - 16 * a * b * d - 36 * a * c * e + 12 * a * c - 12 * a * d * e + 4 * a * d + 36 * c**2 + 24 * c * d + 4 * d**2) + 6 * a * b * c + 2 * a * b * d + 3 * a * c * e + 3 * a * c + 3 * a * d * e + a * d - 18 * c**2 - 18 * c * d - 4 * d**2) / (2 * (-3 * a * e + 9 * c + 3 * d))
      cavity_r = 3 * cavity_r
      if cavity_r > 0 # Choose this construction set
        return constr_set, cavity_r
      end
    end

    fail "Unable to calculate a construction for '#{surface_name}' using the provided assembly R-value (#{assembly_r})."
  end

  def self.pick_sip_construction_set(assembly_r, constr_sets, film_r, surface_name)
    # Picks a construction set from supplied constr_sets for which a positive R-value
    # can be calculated for the unknown insulation to achieve the assembly R-value.

    constr_sets.each do |constr_set|
      fail "Unexpected object." unless constr_set.is_a? SIPConstructionSet

      non_cavity_r = calc_non_cavity_r(film_r, constr_set)
      non_cavity_r += Material.new(nil, constr_set.sheath_thick_in, BaseMaterial.Wood).rvalue

      # Calculate effective SIP core R-value
      # Solved in Wolfram Alpha: https://www.wolframalpha.com/input/?i=1%2FA+%3D+B%2F(C%2BD)+%2B+E%2F(2*F%2BG%2FH*x%2BD)+%2B+(1-B-E)%2F(x%2BD)
      spline_thick_in = 0.5 # in
      ins_thick_in = constr_set.thick_in - (2.0 * spline_thick_in) # in
      framing_r = Material.new(nil, constr_set.thick_in, BaseMaterial.Wood).rvalue
      spline_r = Material.new(nil, spline_thick_in, BaseMaterial.Wood).rvalue
      spline_frac = 4.0 / 48.0 # One 4" spline for every 48" wide panel
      cavity_frac = 1.0 - (spline_frac + constr_set.framing_factor)
      a = assembly_r
      b = constr_set.framing_factor
      c = framing_r
      d = non_cavity_r
      e = spline_frac
      f = spline_r
      g = ins_thick_in
      h = constr_set.thick_in
      cavity_r = (Math.sqrt((a * b * c * g - a * b * d * h - 2 * a * b * f * h + a * c * e * g - a * c * e * h - a * c * g + a * d * e * g - a * d * e * h - a * d * g + c * d * g + c * d * h + 2 * c * f * h + d**2 * g + d**2 * h + 2 * d * f * h)**2 - 4 * (-a * b * g + c * g + d * g) * (a * b * c * d * h + 2 * a * b * c * f * h - a * c * d * h + 2 * a * c * e * f * h - 2 * a * c * f * h - a * d**2 * h + 2 * a * d * e * f * h - 2 * a * d * f * h + c * d**2 * h + 2 * c * d * f * h + d**3 * h + 2 * d**2 * f * h)) - a * b * c * g + a * b * d * h + 2 * a * b * f * h - a * c * e * g + a * c * e * h + a * c * g - a * d * e * g + a * d * e * h + a * d * g - c * d * g - c * d * h - 2 * c * f * h - g * d**2 - d**2 * h - 2 * d * f * h) / (2 * (-a * b * g + c * g + d * g))
      if cavity_r > 0 # Choose this construction set
        return constr_set, cavity_r
      end
    end

    fail "Unable to calculate a construction for '#{surface_name}' using the provided assembly R-value (#{assembly_r})."
  end

  def self.pick_cmu_construction_set(assembly_r, constr_sets, film_r, surface_name)
    # Picks a construction set from supplied constr_sets for which a positive R-value
    # can be calculated for the unknown insulation to achieve the assembly R-value.

    constr_sets.each do |constr_set|
      fail "Unexpected object." unless constr_set.is_a? CMUConstructionSet

      non_cavity_r = calc_non_cavity_r(film_r, constr_set)

      # Calculate effective other CMU R-value
      # Assumes no furring strips
      # Solved in Wolfram Alpha: https://www.wolframalpha.com/input/?i=1%2FA+%3D+B%2F(C%2BE%2Bx)+%2B+(1-B)%2F(D%2BE%2Bx)
      a = assembly_r
      b = constr_set.framing_factor
      c = Material.new(nil, constr_set.thick_in, BaseMaterial.Wood).rvalue # Framing
      d = Material.new(nil, constr_set.thick_in, BaseMaterial.Concrete, constr_set.cond_in).rvalue # Concrete
      e = non_cavity_r
      rigid_r = 0.5 * (Math.sqrt(a**2 - 4 * a * b * c + 4 * a * b * d + 2 * a * c - 2 * a * d + c**2 - 2 * c * d + d**2) + a - c - d - 2 * e)
      if rigid_r > 0 # Choose this construction set
        return constr_set, rigid_r
      end
    end

    fail "Unable to calculate a construction for '#{surface_name}' using the provided assembly R-value (#{assembly_r})."
  end

  def self.pick_icf_construction_set(assembly_r, constr_sets, film_r, surface_name)
    # Picks a construction set from supplied constr_sets for which a positive R-value
    # can be calculated for the unknown insulation to achieve the assembly R-value.

    constr_sets.each do |constr_set|
      fail "Unexpected object." unless constr_set.is_a? ICFConstructionSet

      non_cavity_r = calc_non_cavity_r(film_r, constr_set)

      # Calculate effective ICF rigid ins R-value
      # Solved in Wolfram Alpha: https://www.wolframalpha.com/input/?i=1%2FA+%3D+B%2F(C%2BE)+%2B+(1-B)%2F(D%2BE%2B2*x)
      a = assembly_r
      b = constr_set.framing_factor
      c = Material.new(nil, 2 * constr_set.ins_thick_in + constr_set.concrete_thick_in, BaseMaterial.Wood).rvalue # Framing
      d = Material.new(nil, constr_set.concrete_thick_in, BaseMaterial.Concrete).rvalue # Concrete
      e = non_cavity_r
      icf_r = (a * b * c - a * b * d - a * c - a * e + c * d + c * e + d * e + e**2) / (2 * (a * b - c - e))
      if icf_r > 0 # Choose this construction set
        return constr_set, icf_r
      end
    end

    fail "Unable to calculate a construction for '#{surface_name}' using the provided assembly R-value (#{assembly_r})."
  end

  def self.pick_generic_construction_set(assembly_r, constr_sets, film_r, surface_name)
    # Picks a construction set from supplied constr_sets for which a positive R-value
    # can be calculated for the unknown insulation to achieve the assembly R-value.

    constr_sets.each do |constr_set|
      fail "Unexpected object." unless constr_set.is_a? GenericConstructionSet

      non_cavity_r = calc_non_cavity_r(film_r, constr_set)

      # Calculate effective ins layer R-value
      layer_r = assembly_r - non_cavity_r
      if layer_r > 0 # Choose this construction set
        return constr_set, layer_r
      end
    end

    fail "Unable to calculate a construction for '#{surface_name}' using the provided assembly R-value (#{assembly_r})."
  end

  def self.apply_solar_abs_emittance_to_construction(surface, solar_abs, emitt)
    # Applies the solar absorptance and emittance to the construction's exterior layer
    exterior_material = surface.construction.get.to_LayeredConstruction.get.layers[0].to_StandardOpaqueMaterial.get
    exterior_material.setThermalAbsorptance(emitt)
    exterior_material.setSolarAbsorptance(solar_abs)
    exterior_material.setVisibleAbsorptance(solar_abs)
  end

  def self.check_surface_assembly_rvalue(surface, film_r, assembly_r)
    # Verify that the actual OpenStudio construction R-value matches our target assembly R-value

    constr_r = UnitConversions.convert(1.0 / surface.construction.get.uFactor(0.0).get, 'm^2*k/w', 'hr*ft^2*f/btu') + film_r

    if surface.adjacentFoundation.is_initialized
      foundation = surface.adjacentFoundation.get
      if foundation.interiorVerticalInsulationMaterial.is_initialized
        int_mat = foundation.interiorVerticalInsulationMaterial.get.to_StandardOpaqueMaterial.get
        constr_r += UnitConversions.convert(int_mat.thickness, "m", "ft") / UnitConversions.convert(int_mat.thermalConductivity, "W/(m*K)", "Btu/(hr*ft*R)")
      end
      if foundation.exteriorVerticalInsulationMaterial.is_initialized
        ext_mat = foundation.exteriorVerticalInsulationMaterial.get.to_StandardOpaqueMaterial.get
        constr_r += UnitConversions.convert(ext_mat.thickness, "m", "ft") / UnitConversions.convert(ext_mat.thermalConductivity, "W/(m*K)", "Btu/(hr*ft*R)")
      end
    end

    if (assembly_r - constr_r).abs > 0.01
      fail "Construction R-value (#{constr_r}) does not match Assembly R-value (#{assembly_r}) for '#{surface.name.to_s}'."
    end
  end

  def self.get_attached_system(system_values, building, system_to_search, loop_hvacs)
    return nil if system_values[:distribution_system_idref].nil?

    # Finds the OpenStudio object of the heating (or cooling) system attached (i.e., on the same
    # distribution system) to the current cooling (or heating) system.
    building.elements.each("BuildingDetails/Systems/HVAC/HVACPlant/#{system_to_search}") do |other_sys|
      if system_to_search == "CoolingSystem"
        attached_system_values = HPXML.get_cooling_system_values(cooling_system: other_sys)
      elsif system_to_search == "HeatingSystem"
        attached_system_values = HPXML.get_heating_system_values(heating_system: other_sys)
      end
      next unless system_values[:distribution_system_idref] == attached_system_values[:distribution_system_idref]

      air_loop = loop_hvacs[attached_system_values[:id]]
      if not air_loop.nil?
        return HVAC.get_unitary_system_from_air_loop_hvac(air_loop[0])
      end
    end

    return nil
  end

  def self.set_surface_interior(model, spaces, surface, surface_id, interior_adjacent_to)
    if ["living space"].include? interior_adjacent_to
      surface.setSpace(create_or_get_space(model, spaces, Constants.SpaceTypeLiving))
    elsif ["garage"].include? interior_adjacent_to
      surface.setSpace(create_or_get_space(model, spaces, Constants.SpaceTypeGarage))
    elsif ["basement - unconditioned"].include? interior_adjacent_to
      surface.setSpace(create_or_get_space(model, spaces, Constants.SpaceTypeUnconditionedBasement))
    elsif ["basement - conditioned"].include? interior_adjacent_to
      surface.setSpace(create_or_get_space(model, spaces, Constants.SpaceTypeConditionedBasement))
    elsif ["crawlspace - vented", "crawlspace - unvented"].include? interior_adjacent_to
      surface.setSpace(create_or_get_space(model, spaces, Constants.SpaceTypeCrawl))
    elsif ["attic - unvented", "attic - vented"].include? interior_adjacent_to
      surface.setSpace(create_or_get_space(model, spaces, Constants.SpaceTypeUnconditionedAttic))
    elsif ["attic - conditioned", "flat roof", "cathedral ceiling"].include? interior_adjacent_to
      surface.setSpace(create_or_get_space(model, spaces, Constants.SpaceTypeLiving))
    else
      fail "Unhandled AdjacentTo value (#{interior_adjacent_to}) for surface '#{surface_id}'."
    end
  end

  def self.set_surface_exterior(model, spaces, surface, surface_id, exterior_adjacent_to)
    if ["outside"].include? exterior_adjacent_to
      surface.setOutsideBoundaryCondition("Outdoors")
    elsif ["ground"].include? exterior_adjacent_to
      surface.setOutsideBoundaryCondition("Foundation")
    elsif ["living space"].include? exterior_adjacent_to
      surface.createAdjacentSurface(create_or_get_space(model, spaces, Constants.SpaceTypeLiving))
    elsif ["garage"].include? exterior_adjacent_to
      surface.createAdjacentSurface(create_or_get_space(model, spaces, Constants.SpaceTypeGarage))
    elsif ["basement - unconditioned"].include? exterior_adjacent_to
      surface.createAdjacentSurface(create_or_get_space(model, spaces, Constants.SpaceTypeUnconditionedBasement))
    elsif ["basement - conditioned"].include? exterior_adjacent_to
      surface.createAdjacentSurface(create_or_get_space(model, spaces, Constants.SpaceTypeConditionedBasement))
    elsif ["crawlspace - vented", "crawlspace - unvented"].include? exterior_adjacent_to
      surface.createAdjacentSurface(create_or_get_space(model, spaces, Constants.SpaceTypeCrawl))
    elsif ["attic - unvented", "attic - vented"].include? exterior_adjacent_to
      surface.createAdjacentSurface(create_or_get_space(model, spaces, Constants.SpaceTypeUnconditionedAttic))
    elsif ["attic - conditioned"].include? exterior_adjacent_to
      surface.createAdjacentSurface(create_or_get_space(model, spaces, Constants.SpaceTypeLiving))
    else
      fail "Unhandled AdjacentTo value (#{exterior_adjacent_to}) for surface '#{surface_id}'."
    end
  end

  def self.get_foundation_top(model)
    # Get top of foundation surfaces
    foundation_top = -9999
    model.getSpaces.each do |space|
      next unless Geometry.space_is_below_grade(space)

      space.surfaces.each do |surface|
        surface.vertices.each do |v|
          next if v.z < foundation_top

          foundation_top = v.z
        end
      end
    end

    if foundation_top == -9999
      foundation_top = 9999
      # Pier & beam foundation; get lowest floor vertex
      model.getSpaces.each do |space|
        space.surfaces.each do |surface|
          next unless surface.surfaceType.downcase == "floor"

          surface.vertices.each do |v|
            next if v.z > foundation_top

            foundation_top = v.z
          end
        end
      end
    end

    if foundation_top == 9999
      fail "Could not calculate foundation top."
    end

    return UnitConversions.convert(foundation_top, "m", "ft")
  end

  def self.get_walls_top(model)
    # Get top of wall surfaces
    walls_top = -9999
    model.getSpaces.each do |space|
      space.surfaces.each do |surface|
        next unless surface.surfaceType.downcase == "wall"
        next unless surface.subSurfaces.size == 0

        surface.vertices.each do |v|
          next if v.z < walls_top

          walls_top = v.z
        end
      end
    end

    if walls_top == -9999
      fail "Could not calculate walls top."
    end

    return UnitConversions.convert(walls_top, "m", "ft")
  end

  def self.get_space_from_location(location, object_name, model, spaces)
    num_orig_spaces = spaces.size

    space = nil
    if location == 'living space'
      space = create_or_get_space(model, spaces, Constants.SpaceTypeLiving)
    elsif location == 'basement - conditioned'
      space = create_or_get_space(model, spaces, Constants.SpaceTypeConditionedBasement)
    elsif location == 'basement - unconditioned'
      space = create_or_get_space(model, spaces, Constants.SpaceTypeUnconditionedBasement)
    elsif location == 'garage'
      space = create_or_get_space(model, spaces, Constants.SpaceTypeGarage)
    elsif location == 'attic - unvented' or location == 'attic - vented'
      space = create_or_get_space(model, spaces, Constants.SpaceTypeUnconditionedAttic)
    elsif location == 'crawlspace - unvented' or location == 'crawlspace - vented'
      space = create_or_get_space(model, spaces, Constants.SpaceTypeCrawl)
    end

    if space.nil?
      fail "Unhandled #{object_name} location: #{location}."
    end

    if spaces.size != num_orig_spaces
      fail "#{object_name} location is '#{location}' but building does not have this location specified."
    end

    return space
  end

  def self.get_spaces_of_type(spaces, space_types_list)
    spaces_of_type = []
    space_types_list.each do |space_type|
      spaces_of_type << spaces[space_type] unless spaces[space_type].nil?
    end
    return spaces_of_type
  end

  def self.get_space_of_type(spaces, space_type)
    spaces_of_type = self.get_spaces_of_type(spaces, [space_type])
    if spaces_of_type.size > 1
      fail "Unexpected number of spaces."
    elsif spaces_of_type.size == 1
      return spaces_of_type[0]
    end

    return nil
  end

  def self.assign_space_to_subsurface(surface, subsurface_id, wall_idref, building, spaces, model, subsurface_type)
    # First check walls
    building.elements.each("BuildingDetails/Enclosure/Walls/Wall") do |wall|
      wall_values = HPXML.get_wall_values(wall: wall)
      next unless wall_values[:id] == wall_idref

      interior_adjacent_to = wall_values[:interior_adjacent_to]
      set_surface_interior(model, spaces, surface, subsurface_id, interior_adjacent_to)
      return
    end

    # Next check foundation walls
    if not surface.space.is_initialized
      building.elements.each("BuildingDetails/Enclosure/Foundations/Foundation") do |foundation|
        foundation_values = HPXML.get_foundation_values(foundation: foundation)
        interior_adjacent_to = get_foundation_adjacent_to(foundation_values[:foundation_type])

        foundation.elements.each("FoundationWall") do |foundation_wall|
          foundation_wall_values = HPXML.get_foundation_wall_values(foundation_wall: foundation_wall)
          next unless foundation_wall_values[:id] == wall_idref

          set_surface_interior(model, spaces, surface, subsurface_id, interior_adjacent_to)
          return
        end
      end
    end

    # Next check attic walls
    if not surface.space.is_initialized
      building.elements.each("BuildingDetails/Enclosure/Attics/Attic") do |attic|
        attic_values = HPXML.get_attic_values(attic: attic)
        interior_adjacent_to = get_attic_adjacent_to(attic_values[:attic_type])

        attic.elements.each("Walls/Wall") do |attic_wall|
          attic_wall_values = HPXML.get_attic_wall_values(wall: attic_wall)
          next unless attic_wall_values[:id] == wall_idref

          set_surface_interior(model, spaces, surface, subsurface_id, interior_adjacent_to)
          return
        end
      end
    end

    # Next check garage walls
    if not surface.space.is_initialized
      building.elements.each("BuildingDetails/Enclosure/Garages/Garage") do |garage|
        interior_adjacent_to = "garage"

        garage.elements.each("Walls/Wall") do |garage_wall|
          garage_wall_values = HPXML.get_garage_wall_values(wall: garage_wall)
          next unless garage_wall_values[:id] == wall_idref

          set_surface_interior(model, spaces, surface, subsurface_id, interior_adjacent_to)
          return
        end
      end
    end

    if not surface.space.is_initialized
      fail "Attached wall '#{wall_idref}' not found for #{subsurface_type} '#{subsurface_id}'."
    end
  end

  def self.get_min_neighbor_distance(building)
    min_neighbor_distance = nil
    building.elements.each("BuildingDetails/BuildingSummary/Site/extension/Neighbors/NeighborBuilding") do |neighbor_building|
      neighbor_building_values = HPXML.get_neighbor_building_values(neighbor_building: neighbor_building)
      if min_neighbor_distance.nil?
        min_neighbor_distance = 9e99
      end
      if neighbor_building_values[:distance] < min_neighbor_distance
        min_neighbor_distance = neighbor_building_values[:distance]
      end
    end
    return min_neighbor_distance
  end
end

class WoodStudConstructionSet
  def initialize(stud, framing_factor, rigid_r, osb_thick_in, drywall_thick_in, exterior_material)
    @stud = stud
    @framing_factor = framing_factor
    @rigid_r = rigid_r
    @osb_thick_in = osb_thick_in
    @drywall_thick_in = drywall_thick_in
    @exterior_material = exterior_material
  end
  attr_accessor(:stud, :framing_factor, :rigid_r, :osb_thick_in, :drywall_thick_in, :exterior_material)
end

class SteelStudConstructionSet
  def initialize(cavity_thick_in, corr_factor, framing_factor, rigid_r, osb_thick_in, drywall_thick_in, exterior_material)
    @cavity_thick_in = cavity_thick_in
    @corr_factor = corr_factor
    @framing_factor = framing_factor
    @rigid_r = rigid_r
    @osb_thick_in = osb_thick_in
    @drywall_thick_in = drywall_thick_in
    @exterior_material = exterior_material
  end
  attr_accessor(:cavity_thick_in, :corr_factor, :framing_factor, :rigid_r, :osb_thick_in, :drywall_thick_in, :exterior_material)
end

class DoubleStudConstructionSet
  def initialize(stud, framing_factor, framing_spacing, rigid_r, osb_thick_in, drywall_thick_in, exterior_material)
    @stud = stud
    @framing_factor = framing_factor
    @framing_spacing = framing_spacing
    @rigid_r = rigid_r
    @osb_thick_in = osb_thick_in
    @drywall_thick_in = drywall_thick_in
    @exterior_material = exterior_material
  end
  attr_accessor(:stud, :framing_factor, :framing_spacing, :rigid_r, :osb_thick_in, :drywall_thick_in, :exterior_material)
end

class SIPConstructionSet
  def initialize(thick_in, framing_factor, rigid_r, sheath_thick_in, osb_thick_in, drywall_thick_in, exterior_material)
    @thick_in = thick_in
    @framing_factor = framing_factor
    @rigid_r = rigid_r
    @sheath_thick_in = sheath_thick_in
    @osb_thick_in = osb_thick_in
    @drywall_thick_in = drywall_thick_in
    @exterior_material = exterior_material
  end
  attr_accessor(:thick_in, :framing_factor, :rigid_r, :sheath_thick_in, :osb_thick_in, :drywall_thick_in, :exterior_material)
end

class CMUConstructionSet
  def initialize(thick_in, cond_in, framing_factor, osb_thick_in, drywall_thick_in, exterior_material)
    @thick_in = thick_in
    @cond_in = cond_in
    @framing_factor = framing_factor
    @osb_thick_in = osb_thick_in
    @drywall_thick_in = drywall_thick_in
    @exterior_material = exterior_material
    @rigid_r = nil # solved for
  end
  attr_accessor(:thick_in, :cond_in, :framing_factor, :rigid_r, :osb_thick_in, :drywall_thick_in, :exterior_material)
end

class ICFConstructionSet
  def initialize(ins_thick_in, concrete_thick_in, framing_factor, rigid_r, osb_thick_in, drywall_thick_in, exterior_material)
    @ins_thick_in = ins_thick_in
    @concrete_thick_in = concrete_thick_in
    @framing_factor = framing_factor
    @rigid_r = rigid_r
    @osb_thick_in = osb_thick_in
    @drywall_thick_in = drywall_thick_in
    @exterior_material = exterior_material
  end
  attr_accessor(:ins_thick_in, :concrete_thick_in, :framing_factor, :rigid_r, :osb_thick_in, :drywall_thick_in, :exterior_material)
end

class GenericConstructionSet
  def initialize(rigid_r, osb_thick_in, drywall_thick_in, exterior_material)
    @rigid_r = rigid_r
    @osb_thick_in = osb_thick_in
    @drywall_thick_in = drywall_thick_in
    @exterior_material = exterior_material
  end
  attr_accessor(:rigid_r, :osb_thick_in, :drywall_thick_in, :exterior_material)
end

def to_beopt_fuel(fuel)
  return { "natural gas" => Constants.FuelTypeGas,
           "fuel oil" => Constants.FuelTypeOil,
           "propane" => Constants.FuelTypePropane,
           "electricity" => Constants.FuelTypeElectric,
           "wood" => Constants.FuelTypeWood,
           "wood pellets" => Constants.FuelTypeWoodPellets }[fuel]
end

def to_beopt_wh_type(type)
  return { 'storage water heater' => Constants.WaterHeaterTypeTank,
           'instantaneous water heater' => Constants.WaterHeaterTypeTankless,
           'heat pump water heater' => Constants.WaterHeaterTypeHeatPump }[type]
end

def get_foundation_adjacent_to(fnd_type)
  if fnd_type == "ConditionedBasement"
    return "basement - conditioned"
  elsif fnd_type == "UnconditionedBasement"
    return "basement - unconditioned"
  elsif fnd_type == "VentedCrawlspace"
    return "crawlspace - vented"
  elsif fnd_type == "UnventedCrawlspace"
    return "crawlspace - unvented"
  elsif fnd_type == "SlabOnGrade"
    return "living space"
  elsif fnd_type == "Ambient"
    return "outside"
  end

  fail "Unexpected foundation type (#{fnd_type})."
end

def get_attic_adjacent_to(attic_type)
  if attic_type == "UnventedAttic"
    return "attic - unvented"
  elsif attic_type == "VentedAttic"
    return "attic - vented"
  elsif attic_type == "ConditionedAttic"
    return "attic - conditioned"
  elsif attic_type == "CathedralCeiling"
    return "living space"
  elsif attic_type == "FlatRoof"
    return "living space"
  end

  fail "Unexpected attic type (#{attic_type})."
end

def is_external_thermal_boundary(interior_adjacent_to, exterior_adjacent_to)
  interior_conditioned = is_adjacent_to_conditioned(interior_adjacent_to)
  exterior_conditioned = is_adjacent_to_conditioned(exterior_adjacent_to)
  return (interior_conditioned != exterior_conditioned)
end

def is_adjacent_to_conditioned(adjacent_to)
  if adjacent_to == "living space"
    return true
  elsif adjacent_to == "garage"
    return false
  elsif adjacent_to == "attic - vented"
    return false
  elsif adjacent_to == "attic - unvented"
    return false
  elsif adjacent_to == "attic - conditioned"
    return true
  elsif adjacent_to == "basement - unconditioned"
    return false
  elsif adjacent_to == "basement - conditioned"
    return true
  elsif adjacent_to == "crawlspace - vented"
    return false
  elsif adjacent_to == "crawlspace - unvented"
    return false
  elsif adjacent_to == "outside"
    return false
  elsif adjacent_to == "ground"
    return false
  end

  fail "Unexpected adjacent_to (#{adjacent_to})."
end

def get_ac_num_speeds(seer)
  if seer <= 15
    return "1-Speed"
  elsif seer <= 21
    return "2-Speed"
  elsif seer > 21
    return "Variable-Speed"
  end
end

def get_ashp_num_speeds_by_seer(seer)
  if seer <= 15
    return "1-Speed"
  elsif seer <= 21
    return "2-Speed"
  elsif seer > 21
    return "Variable-Speed"
  end
end

def get_ashp_num_speeds_by_hspf(hspf)
  if hspf <= 8.5
    return "1-Speed"
  elsif hspf <= 9.5
    return "2-Speed"
  elsif hspf > 9.5
    return "Variable-Speed"
  end
end

def get_fan_power_installed(seer)
  if seer <= 15
    return 0.365 # W/cfm
  else
    return 0.14 # W/cfm
  end
end

class OutputVars
  def self.SpaceHeatingElectricity
    return { 'OpenStudio::Model::CoilHeatingDXSingleSpeed' => ['Heating Coil Electric Energy', 'Heating Coil Crankcase Heater Electric Energy', 'Heating Coil Defrost Electric Energy'],
             'OpenStudio::Model::CoilHeatingDXMultiSpeed' => ['Heating Coil Electric Energy', 'Heating Coil Crankcase Heater Electric Energy', 'Heating Coil Defrost Electric Energy'],
             'OpenStudio::Model::CoilHeatingElectric' => ['Heating Coil Electric Energy', 'Heating Coil Crankcase Heater Electric Energy', 'Heating Coil Defrost Electric Energy'],
             'OpenStudio::Model::CoilHeatingWaterToAirHeatPumpEquationFit' => ['Heating Coil Electric Energy', 'Heating Coil Crankcase Heater Electric Energy', 'Heating Coil Defrost Electric Energy'],
             'OpenStudio::Model::CoilHeatingGas' => [],
             'OpenStudio::Model::ZoneHVACBaseboardConvectiveElectric' => ['Baseboard Electric Energy'],
             'OpenStudio::Model::BoilerHotWater' => ['Boiler Electric Energy'],
             'OpenStudio::Model::FanOnOff' => ['Fan Electric Energy'] }
  end

  def self.SpaceHeatingFuel
    return { 'OpenStudio::Model::CoilHeatingDXSingleSpeed' => [],
             'OpenStudio::Model::CoilHeatingDXMultiSpeed' => [],
             'OpenStudio::Model::CoilHeatingElectric' => [],
             'OpenStudio::Model::CoilHeatingWaterToAirHeatPumpEquationFit' => [],
             'OpenStudio::Model::CoilHeatingGas' => ['Heating Coil Gas Energy', 'Heating Coil Propane Energy', 'Heating Coil FuelOil#1 Energy'],
             'OpenStudio::Model::ZoneHVACBaseboardConvectiveElectric' => ['Baseboard Gas Energy', 'Baseboard Propane Energy', 'Baseboard FuelOil#1 Energy'],
             'OpenStudio::Model::BoilerHotWater' => ['Boiler Gas Energy', 'Boiler Propane Energy', 'Boiler FuelOil#1 Energy'],
             'OpenStudio::Model::FanOnOff' => [] }
  end

  def self.SpaceHeatingLoad
    return { 'OpenStudio::Model::CoilHeatingDXSingleSpeed' => ['Heating Coil Heating Energy'],
             'OpenStudio::Model::CoilHeatingDXMultiSpeed' => ['Heating Coil Heating Energy'],
             'OpenStudio::Model::CoilHeatingElectric' => ['Heating Coil Heating Energy'],
             'OpenStudio::Model::CoilHeatingWaterToAirHeatPumpEquationFit' => ['Heating Coil Heating Energy'],
             'OpenStudio::Model::CoilHeatingGas' => ['Heating Coil Heating Energy'],
             'OpenStudio::Model::ZoneHVACBaseboardConvectiveElectric' => ['Baseboard Total Heating Energy'],
             'OpenStudio::Model::BoilerHotWater' => ['Boiler Heating Energy'],
             'OpenStudio::Model::FanOnOff' => ['Fan Electric Energy'] }
  end

  def self.SpaceCoolingElectricity
    return { 'OpenStudio::Model::CoilCoolingDXSingleSpeed' => ['Cooling Coil Electric Energy', 'Cooling Coil Crankcase Heater Electric Energy'],
             'OpenStudio::Model::CoilCoolingDXMultiSpeed' => ['Cooling Coil Electric Energy', 'Cooling Coil Crankcase Heater Electric Energy'],
             'OpenStudio::Model::CoilCoolingWaterToAirHeatPumpEquationFit' => ['Cooling Coil Electric Energy', 'Cooling Coil Crankcase Heater Electric Energy'],
             'OpenStudio::Model::FanOnOff' => ['Fan Electric Energy'] }
  end

  def self.SpaceCoolingLoad
    return { 'OpenStudio::Model::CoilCoolingDXSingleSpeed' => ['Cooling Coil Total Cooling Energy'],
             'OpenStudio::Model::CoilCoolingDXMultiSpeed' => ['Cooling Coil Total Cooling Energy'],
             'OpenStudio::Model::CoilCoolingWaterToAirHeatPumpEquationFit' => ['Cooling Coil Total Cooling Energy'],
             'OpenStudio::Model::FanOnOff' => ['Fan Electric Energy'] }
  end

  def self.WaterHeatingElectricity
    return { 'OpenStudio::Model::WaterHeaterMixed' => ['Water Heater Electric Energy', 'Water Heater Off Cycle Parasitic Electric Energy', 'Water Heater On Cycle Parasitic Electric Energy'],
             'OpenStudio::Model::WaterHeaterStratified' => ['Water Heater Electric Energy', 'Water Heater Off Cycle Parasitic Electric Energy', 'Water Heater On Cycle Parasitic Electric Energy'],
             'OpenStudio::Model::CoilWaterHeatingAirToWaterHeatPumpWrapped' => ['Cooling Coil Water Heating Electric Energy'],
             'OpenStudio::Model::WaterUseConnections' => [],
             'OpenStudio::Model::ElectricEquipment' => [] }
  end

  def self.WaterHeatingElectricityRecircPump
    return { 'OpenStudio::Model::WaterHeaterMixed' => [],
             'OpenStudio::Model::WaterHeaterStratified' => [],
             'OpenStudio::Model::CoilWaterHeatingAirToWaterHeatPumpWrapped' => [],
             'OpenStudio::Model::WaterUseConnections' => [],
             'OpenStudio::Model::ElectricEquipment' => ['Electric Equipment Electric Energy'] }
  end

  def self.WaterHeatingFuel
    return { 'OpenStudio::Model::WaterHeaterMixed' => ['Water Heater Gas Energy', 'Water Heater Propane Energy', 'Water Heater FuelOil#1 Energy'],
             'OpenStudio::Model::WaterHeaterStratified' => ['Water Heater Gas Energy', 'Water Heater Propane Energy', 'Water Heater FuelOil#1 Energy'],
             'OpenStudio::Model::CoilWaterHeatingAirToWaterHeatPumpWrapped' => [],
             'OpenStudio::Model::WaterUseConnections' => [],
             'OpenStudio::Model::ElectricEquipment' => [] }
  end

  def self.WaterHeatingLoad
    return { 'OpenStudio::Model::WaterHeaterMixed' => [],
             'OpenStudio::Model::WaterHeaterStratified' => [],
             'OpenStudio::Model::CoilWaterHeatingAirToWaterHeatPumpWrapped' => [],
             'OpenStudio::Model::WaterUseConnections' => ['Water Use Connections Plant Hot Water Energy'],
             'OpenStudio::Model::ElectricEquipment' => [] }
  end
end

# register the measure to be used by the application
HPXMLTranslator.new.registerWithApplication
