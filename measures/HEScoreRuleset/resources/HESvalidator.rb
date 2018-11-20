class HEScoreValidator
  def self.run_validator(hpxml_doc)
    # A hash of hashes that defines the XML elements used by the Home Energy Score HPXML Use Case.
    #
    # Example:
    #
    # use_case = {
    #     nil => {
    #         'floor_area' => one,            # 1 element required always
    #         'garage_area' => zero_or_one,   # 0 or 1 elements required always
    #         'walls' => one_or_more,         # 1 or more elements required always
    #     },
    #     '/walls' => {
    #         'rvalue' => one,                # 1 element required if /walls element exists (conditional)
    #         'windows' => zero_or_one,       # 0 or 1 elements required if /walls element exists (conditional)
    #         'layers' => one_or_more,        # 1 or more elements required if /walls element exists (conditional)
    #     }
    # }
    #

    one = [1]
    zero = [0]
    zero_or_one = [0, 1]
    zero_or_more = nil
    one_or_more = []

    requirements = {

      # Root
      nil => {
        '/HPXML/XMLTransactionHeaderInformation/XMLType' => one, # Required by HPXML schema
        '/HPXML/XMLTransactionHeaderInformation/XMLGeneratedBy' => one, # Required by HPXML schema
        '/HPXML/XMLTransactionHeaderInformation/CreatedDateAndTime' => one, # Required by HPXML schema
        '/HPXML/XMLTransactionHeaderInformation/Transaction' => one, # Required by HPXML schema

        '/HPXML/SoftwareInfo/SoftwareProgramUsed' => one,
        '/HPXML/SoftwareInfo/SoftwareProgramVersion' => one,

        '/HPXML/Building' => one,
        '/HPXML/Building/BuildingID' => one, # Required by HPXML schema
        '/HPXML/Building/Site/SiteID' => one, # Required by HPXML schema

        '/HPXML/Building/ProjectStatus/EventType' => one, # Required by HPXML schema

        '/HPXML/Building/BuildingDetails/BuildingSummary/Site[Surroundings="stand-alone" or Surroundings="attached on one side" or Surroundings="attached on two sides"]' => one,
        '/HPXML/Building/BuildingDetails/BuildingSummary/Site/OrientationOfFrontOfHome' => one,
        '/HPXML/Building/BuildingDetails/BuildingSummary/BuildingConstruction/YearBuilt' => one,
        '/HPXML/Building/BuildingDetails/BuildingSummary/BuildingConstruction[ResidentialFacilityType="single-family detached" or ResidentialFacilityType="single-family attached"]' => one,
        '/HPXML/Building/BuildingDetails/BuildingSummary/BuildingConstruction/NumberofConditionedFloorsAboveGrade' => one,
        '/HPXML/Building/BuildingDetails/BuildingSummary/BuildingConstruction/AverageCeilingHeight' => one,
        '/HPXML/Building/BuildingDetails/BuildingSummary/BuildingConstruction/NumberofBedrooms' => one,
        '/HPXML/Building/BuildingDetails/BuildingSummary/BuildingConstruction/ConditionedFloorArea' => one,

        '/HPXML/Building/BuildingDetails/Enclosure/AirInfiltration/AirInfiltrationMeasurement' => one, # See [AirInfiltration]

        '/HPXML/Building/BuildingDetails/Enclosure/AtticAndRoof/Roofs/Roof' => one_or_more, # See [Roof]
        '/HPXML/Building/BuildingDetails/Enclosure/AtticAndRoof/Attics/Attic' => one_or_more, # See [Attic]
        '/HPXML/Building/BuildingDetails/Enclosure/Foundations/Foundation' => one_or_more, # See [Foundation]
        '/HPXML/Building/BuildingDetails/Enclosure/Walls/Wall' => one_or_more, # See [Wall]
        '/HPXML/Building/BuildingDetails/Enclosure/Windows/Window' => one_or_more, # See [Window]
        '/HPXML/Building/BuildingDetails/Enclosure/Skylights/Skylight' => zero_or_more, # See [Skylight]

        '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatingSystem' => zero_or_one, # See [HeatingSystem]
        '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/CoolingSystem' => zero_or_one, # See [CoolingSystem]
        '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatPump' => zero_or_one, # See [HeatPump]
        '/HPXML/Building/BuildingDetails/Systems/WaterHeating' => zero_or_one, # See [WaterHeatingSystem]
        '/HPXML/Building/BuildingDetails/Systems/Photovoltaics' => zero_or_one, # See [PVSystem]
      },

      # [AirInfiltration]
      'BuildingDetails/Enclosure/AirInfiltration/AirInfiltrationMeasurement' => {
        'SystemIdentifier' => one, # Required by HPXML schema
        '[[HousePressure="50"]/BuildingAirLeakage[UnitofMeasure="CFM"]/AirLeakage] | [LeakinessDescription="tight" or LeakinessDescription="average"]' => one,
        '[TypeOfInfiltrationMeasurement="blower door" or TypeOfInfiltrationMeasurement="estimate"]' => one,
      },

      # [Roof]
      '/HPXML/Building/BuildingDetails/Enclosure/AtticAndRoof/Roofs/Roof' => {
        'SystemIdentifier' => one, # Required by HPXML schema
        '[RoofColor="light" or RoofColor="medium" or RoofColor="medium dark" or RoofColor="dark" or RoofColor="white" or RoofColor="reflective"]' => one,
        'SolarAbsorptance' => one,
        '[RoofType="slate or tile shingles" or RoofType="wood shingles or shakes" or RoofType="asphalt or fiberglass shingles" or RoofType="plastic/rubber/synthetic sheeting" or RoofType="concrete"]' => one,
        'RadiantBarrier' => one,
        '/HPXML/Building/BuildingDetails/Enclosure/Skylights' => zero_or_one, # See [Skylight]
      },

      # [Attic]
      '/HPXML/Building/BuildingDetails/Enclosure/AtticAndRoof/Attics/Attic' => {
        'SystemIdentifier' => one, # Required by HPXML schema
        'AttachedToRoof' => one,
        '[AtticType="vented attic" or AtticType="cape cod" or AtticType="cathedral ceiling"]' => one, # See [AtticType=Vented] or [AtticType=Cape] or [AtticType=Cathedral]
      },

      ## [AtticType=Vented]
      '/HPXML/Building/BuildingDetails/Enclosure/AtticAndRoof/Attics/Attic[AtticType="vented attic"]' => {
        'AtticFloorInsulation/Layer/NominalRValue' => one,
        'AtticRoofInsulation/Layer/NominalRValue' => one,
        'Area' => one,
      },

      ## [AtticType=Cape]
      '/HPXML/Building/BuildingDetails/Enclosure/AtticAndRoof/Attics/Attic[AtticType="cape cod"]' => {
        'AtticFloorInsulation/Layer/NominalRValue' => one,
        'AtticRoofInsulation/Layer/NominalRValue' => one,
        'Area' => one,
      },

      ## [AtticType=Cathedral]
      '/HPXML/Building/BuildingDetails/Enclosure/AtticAndRoof/Attics/Attic[AtticType="cathedral ceiling"]' => {
        'AtticRoofInsulation/Layer/NominalRValue' => one,
      },

      # [Foundation]
      '/HPXML/Building/BuildingDetails/Enclosure/Foundations/Foundation' => {
        'SystemIdentifier' => one, # Required by HPXML schema
        'FoundationType[Basement | Crawlspace | SlabOnGrade]' => one, # See [FoundationType=Basement] or [FoundationType=Crawl] or [FoundationType=Slab]
      },

      ## [FoundationType=Basement]
      '/HPXML/Building/BuildingDetails/Enclosure/Foundations/Foundation[FoundationType/Basement]' => {
        'FoundationType/Basement/Conditioned' => one,
        'FoundationWall/Insulation/Layer/NominalRValue' => one,
      },

      ## [FoundationType=Crawl]
      '/HPXML/Building/BuildingDetails/Enclosure/Foundations/Foundation[FoundationType/Crawlspace]' => {
        'FoundationType/Crawlspace/Vented' => one,
        'FrameFloor/Area' => one,
        'FrameFloor/Insulation/Layer/NominalRValue' => one, # FIXME: Basement too?
        'FoundationWall/Insulation/Layer/NominalRValue' => one,
      },

      ## [FoundationType=Slab]
      '/HPXML/Building/BuildingDetails/Enclosure/Foundations/Foundation[FoundationType/SlabOnGrade]' => {
        'Area' => one,
        'PerimeterInsulation/Layer/NominalRValue' => one,
      },

      # [Wall]
      '/HPXML/Building/BuildingDetails/Enclosure/Walls/Wall' => {
        'SystemIdentifier' => one, # Required by HPXML schema
        'WallType[WoodStud | StructuralBrick | ConcreteMasonryUnit | StrawBale]' => one, # See [WallType=WoodStud] or [WallType=NotWoodStud]
        'Orientation' => one,
        '[count(Siding)=0 or Siding="wood siding" or Siding="stucco" or Siding="vinyl siding" or Siding="aluminum siding" or Siding="brick veneer"]' => one,
        'Insulation/Layer/NominalRValue' => one,
      },

      ## [WallType=WoodStud]
      '/HPXML/Building/BuildingDetails/Enclosure/Walls/Wall[WallType/WoodStud]' => {
        'Insulation/Layer[InstallationType="cavity" or InstallationType="continuous"]' => one,
        'OptimumValueEngineering' => one,
      },

      ## [WallType=NotWoodStud]
      '/HPXML/Building/BuildingDetails/Enclosure/Walls/Wall[WallType/StructuralBrick | WallType/ConcreteMasonryUnit | WallType/StrawBale]' => {
        'Insulation/Layer[InstallationType="cavity"]' => one,
      },

      # [Window]
      '/HPXML/Building/BuildingDetails/Enclosure/Windows/Window' => {
        'SystemIdentifier' => one, # Required by HPXML schema
        'Area' => one,
        'Orientation' => one,
        'AttachedToWall' => one,
        '[FrameType | UFactor]' => one, # See [WindowType=Detailed] or [WindowType=Simple]
      },

      ## [WindowType=Detailed]
      '/HPXML/Building/BuildingDetails/Enclosure/Windows/Window[FrameType]' => {
        '[FrameType/Aluminum/ThermalBreak | FrameType/Wood]' => one,
        '[GlassLayers="single-pane" or GlassLayers="double-pane" or GlassLayers="triple-pane"]' => one,
        '[count(GlassType)=0 or GlassType="tinted/reflective" or GlassType="reflective" or GlassType="low-e"]' => one,
        '[count(GasFill)=0 or GasFill="air" or GasFill="argon"]' => one,
      },

      ## [WindowType=Simple]
      '/HPXML/Building/BuildingDetails/Enclosure/Windows/Window[UFactor]' => {
        'SHGC' => one,
      },

      # [Skylight]
      '/HPXML/Building/BuildingDetails/Enclosure/Skylights/Skylight' => {
        'SystemIdentifier' => one, # Required by HPXML schema
        'Area' => one,
        'AttachedToRoof' => one,
        '[FrameType | UFactor]' => one, # See [SkylightType=Detailed] or [SkylightType=Simple]
      },

      ## [SkylightType=Detailed]
      '/HPXML/Building/BuildingDetails/Enclosure/Skylights/Skylight[FrameType]' => {
        '[FrameType/Aluminum/ThermalBreak | FrameType/Wood]' => one,
        '[GlassLayers="single-pane" or GlassLayers="double-pane" or GlassLayers="triple-pane"]' => one,
        '[count(GlassType)=0 or GlassType="tinted/reflective" or GlassType="reflective" or GlassType="low-e"]' => one,
        '[count(GasFill)=0 or GasFill="air" or GasFill="argon"]' => one,
      },

      ## [SkylightType=Simple]
      '/HPXML/Building/BuildingDetails/Enclosure/Skylights/Skylight[UFactor]' => {
        'SHGC' => one,
      },

      # [HeatingSystem]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatingSystem' => {
        'SystemIdentifier' => one, # Required by HPXML schema
        'HeatingSystemType[ElectricResistance | Furnace | WallFurnace | Boiler | Stove]' => one, # See [HeatingType=Resistance] or [HeatingType=Furnace] or [HeatingType=WallFurnace] or [HeatingType=Boiler] or [HeatingType=Stove]
        'FractionHeatLoadServed' => one,
      },

      ## [HeatingType=Resistance]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatingSystem[HeatingSystemType/ElectricResistance]' => {
        'DistributionSystem' => zero,
      },

      ## [HeatingType=Furnace]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatingSystem[HeatingSystemType/Furnace]' => {
        'DistributionSystem' => one, # See [HVACDistribution]
        '[HeatingSystemFuel="electricity" or HeatingSystemFuel="natural gas" or HeatingSystemFuel="fuel oil" or HeatingSystemFuel="propane"]' => one,
        '[YearInstalled | AnnualHeatingEfficiency[Units="AFUE"]/Value]' => one,
      },

      ## [HeatingType=WallFurnace]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatingSystem[HeatingSystemType/WallFurnace]' => {
        'DistributionSystem' => zero,
        '[HeatingSystemFuel="electricity" or HeatingSystemFuel="natural gas" or HeatingSystemFuel="fuel oil" or HeatingSystemFuel="propane"]' => one,
        '[YearInstalled | AnnualHeatingEfficiency[Units="AFUE"]/Value]' => one,
      },

      ## [HeatingType=Boiler]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatingSystem[HeatingSystemType/Boiler]' => {
        'DistributionSystem' => zero,
        '[HeatingSystemFuel="electricity" or HeatingSystemFuel="natural gas" or HeatingSystemFuel="fuel oil" or HeatingSystemFuel="propane"]' => one,
        '[YearInstalled | AnnualHeatingEfficiency[Units="AFUE"]/Value]' => one,
      },

      ## [HeatingType=Stove]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatingSystem[HeatingSystemType/Stove]' => {
        'DistributionSystem' => zero,
        '[HeatingSystemFuel="wood" or HeatingSystemFuel="wood pellets"]' => one,
      },

      # [CoolingSystem]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/CoolingSystem' => {
        'SystemIdentifier' => one, # Required by HPXML schema
        '[CoolingSystemType="central air conditioning" or CoolingSystemType="room air conditioner" or CoolingSystemType="evaporative cooler"]' => one, # See [CoolingType=CentralAC] or [CoolingType=RoomAC] or [CoolingType=EvapCooler]
        'FractionCoolLoadServed' => one,
      },

      ## [CoolingType=CentralAC]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/CoolingSystem[CoolingSystemType="central air conditioning"]' => {
        'DistributionSystem' => one, # See [HVACDistribution]
        '[YearInstalled | AnnualCoolingEfficiency[Units="SEER"]/Value]' => one,
      },

      ## [CoolingType=RoomAC]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/CoolingSystem[CoolingSystemType="room air conditioning"]' => {
        'DistributionSystem' => zero,
        '[YearInstalled | AnnualCoolingEfficiency[Units="EER"]/Value]' => one,
      },

      ## [CoolingType=EvapCooler]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/CoolingSystem[CoolingSystemType="evaporative cooler"]' => {
        'DistributionSystem' => zero,
      },

      # [HeatPump]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatPump' => {
        'SystemIdentifier' => one, # Required by HPXML schema
        '[HeatPumpType="air-to-air" or HeatPumpType="mini-split" or HeatPumpType="ground-to-air"]' => one, # See [HeatPumpType=ASHP] or [HeatPumpType=MSHP] or [HeatPumpType=GSHP]
        'FractionHeatLoadServed' => one,
        'FractionCoolLoadServed' => one,
      },

      ## [HeatPumpType=ASHP]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatPump[HeatPumpType="air-to-air"]' => {
        'DistributionSystem' => one, # See [HVACDistribution]
        '[YearInstalled | AnnualCoolingEfficiency[Units="SEER"]/Value]' => one,
        '[YearInstalled | AnnualHeatingEfficiency[Units="HSPF"]/Value]' => one,
      },

      ## [HeatPumpType=MSHP]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatPump[HeatPumpType="mini-split"]' => {
        # FIXME: 'DistributionSystem' => one, # See [HVACDistribution]
        '[YearInstalled | AnnualCoolingEfficiency[Units="SEER"]/Value]' => one,
        '[YearInstalled | AnnualHeatingEfficiency[Units="HSPF"]/Value]' => one,
      },

      ## [HeatPumpType=GSHP]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatPump[HeatPumpType="ground-to-air"]' => {
        'DistributionSystem' => one, # See [HVACDistribution]
        '[YearInstalled | AnnualCoolingEfficiency[Units="EER"]/Value]' => one,
        '[YearInstalled | AnnualHeatingEfficiency[Units="COP"]/Value]' => one,
      },

      # [HVACDistribution]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACDistribution' => {
        'SystemIdentifier' => one, # Required by HPXML schema
        'DistributionSystemType/AirDistribution/Ducts' => one_or_more, # See [HVACDuct]
        'HVACDistributionImprovement/DuctSystemSealed' => one,
      },

      ## [HVACDuct]
      '/HPXML/Building/BuildingDetails/Systems/HVAC/HVACDistribution/DistributionSystemType/AirDistribution/Ducts' => {
        '[DuctLocation="conditioned space" or DuctLocation="unconditioned basement" or DuctLocation="unvented crawlspace" or DuctLocation="vented crawlspace" or DuctLocation="unconditioned attic"]' => one,
        'FractionDuctArea' => one,
        'extension/hescore_ducts_insulated' => one,
      },

      # [WaterHeatingSystem]
      '/HPXML/Building/BuildingDetails/Systems/WaterHeating/WaterHeatingSystem' => {
        'SystemIdentifier' => one, # Required by HPXML schema
        '[WaterHeaterType="storage water heater" or WaterHeaterType="heat pump water heater"]' => one, # See [WHType=Tank] or [WHType=HeatPump]
      },

      ## [WHType=Tank]
      '/HPXML/Building/BuildingDetails/Systems/WaterHeating/WaterHeatingSystem[WaterHeaterType="storage water heater"]' => {
        '[FuelType="natural gas" or FuelType="fuel oil" or FuelType="propane" or FuelType="electricity"]' => one, # If not electricity, see [WHType=FuelTank]
        '[YearInstalled | EnergyFactor]' => one,
      },

      ## [WHType=HeatPump]
      '/HPXML/Building/BuildingDetails/Systems/WaterHeating/WaterHeatingSystem[WaterHeaterType="heat pump water heater"]' => {
        'EnergyFactor' => one,
      },

      # [PVSystem]
      '/HPXML/Building/BuildingDetails/Systems/Photovoltaics/PVSystem' => {
        'SystemIdentifier' => one, # Required by HPXML schema
        '[MaxPowerOutput | extension/hescore_num_panels]' => one,
        'ArrayOrientation' => one,
      },
    }

    # TODO: Make common across all validators
    # TODO: Profile code for runtime improvements
    errors = []
    requirements.each do |parent, requirement|
      if parent.nil? # Unconditional
        requirement.each do |child, expected_sizes|
          next if expected_sizes.nil?

          xpath = combine_into_xpath(parent, child)
          actual_size = REXML::XPath.first(hpxml_doc, "count(#{xpath})")
          check_number_of_elements(actual_size, expected_sizes, xpath, errors)
        end
      else # Conditional based on parent element existence
        next if hpxml_doc.elements[parent].nil? # Skip if parent element doesn't exist

        hpxml_doc.elements.each(parent) do |parent_element|
          requirement.each do |child, expected_sizes|
            next if expected_sizes.nil?

            xpath = combine_into_xpath(parent, child)
            actual_size = REXML::XPath.first(parent_element, "count(#{child})")
            check_number_of_elements(actual_size, expected_sizes, xpath, errors)
          end
        end
      end
    end

    return errors
  end

  def self.check_number_of_elements(actual_size, expected_sizes, xpath, errors)
    if expected_sizes.size > 0
      return if expected_sizes.include?(actual_size)

      errors << "Expected #{expected_sizes.to_s} element(s) but found #{actual_size.to_s} element(s) for xpath: #{xpath}"
    else
      return if actual_size > 0

      errors << "Expected 1 or more element(s) but found 0 elements for xpath: #{xpath}"
    end
  end

  def self.combine_into_xpath(parent, child)
    if parent.nil?
      return child
    elsif child.start_with?("[")
      return [parent, child].join('')
    end

    return [parent, child].join('/')
  end
end
