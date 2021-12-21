import csv
import json
import pathlib
import re


def main():
    here = pathlib.Path(__file__).resolve().parent
    json_schema_filename = here / '..' / '..' / '..' / 'hescore-hpxml' / 'hescorehpxml' / 'schemas' / 'hescore_json.schema.json'
    assert json_schema_filename.exists()

    with json_schema_filename.open('r') as f:
        json_schema = json.load(f)

    knee_wall_assembly_codes = json_schema['properties']['building']['properties']['zone']['properties']['zone_roof']['items']['properties']['knee_wall']['properties']['assembly_code']['enum']

    # From https://coloradoenergy.org/procorner/stuff/r-values.htm
    # TODO: Check against ASHRAE fundamentals
    int_air_film_r_value = 0.68
    gyp_r_value = 0.45
    wood_stud_r_value = 4.38
    stud_spacing = 16
    wood_stud_width = 3.5

    csv_filename = here / 'lu_knee_wall_eff_rvalue.csv'
    with csv_filename.open('w') as f:
        csv_writer = csv.writer(f)
        csv_writer.writerow(['doe2code', 'U-value', 'Eff-R-value'])
        for assembly_code in knee_wall_assembly_codes:
            cav_r_value = int(re.match(r"kwwf(\d+)", assembly_code).group(1))
            assembly_r_value = 2 * int_air_film_r_value + gyp_r_value
            if cav_r_value > 0:
                assembly_r_value += 1 / (
                    wood_stud_width / stud_spacing / wood_stud_r_value + 
                    (1 - wood_stud_width / stud_spacing) / cav_r_value
                )
            assembly_u_value = 1 / assembly_r_value
            csv_writer.writerow([assembly_code, f"{assembly_u_value:.3f}", f"{assembly_r_value:.1f}"])


if __name__ == '__main__':
    main()
