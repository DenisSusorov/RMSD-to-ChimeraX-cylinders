#!/bin/bash

# Default color range parameters
min_color_rmsd=0.0
max_color_rmsd=1.0

# Function to display usage
usage() {
    echo "Usage: $0 [options] pdb_files... radius"
    echo "Options:"
    echo "  --min-rmsd MIN    Minimum RMSD for color mapping (default: 0.0)"
    echo "  --max-rmsd MAX    Maximum RMSD for color mapping (default: 1.0)"
    exit 1
}

# Parse command-line arguments
PARSED_ARGUMENTS=$(getopt -a -n rmsd_script -o m:x: --long min-rmsd:,max-rmsd: -- "$@")
VALID_ARGUMENTS=$?
[ $VALID_ARGUMENTS -ne 0 ] && usage

eval set -- "$PARSED_ARGUMENTS"

# Extract options
while :
do
    case "$1" in
        --min-rmsd)
            min_color_rmsd="$2"
            shift 2
            ;;
        --max-rmsd)
            max_color_rmsd="$2"
            shift 2
            ;;
        --) 
            shift
            break
            ;;
        *)
            usage
            ;;
    esac
done

# Check for input files and radius argument
if [ "$#" -lt 2 ]; then
    usage
fi

# Extract last argument as cylinder radius, rest are PDB files
radius="${!#}"
pdb_files=("${@:1:$#-1}")
output_bild="max_rmsd.bild"

# Step 1: Extract only ATOM records and find common atoms using substr($0,12,20)
echo "Extracting common atoms from ATOM records only..."
awk '
    /^ATOM/ { 
        key = substr($0, 12, 20);
        c[key]++;
    }
    END { 
        for (k in c) if (c[k] == ARGIND) print k;
    }
' "${pdb_files[@]}" > common_atoms.txt

# Step 2: Extract coordinates of common atoms from each PDB
echo "Extracting coordinates..."
rm -f rmsd_data.txt
for pdb in "${pdb_files[@]}"; do
    grep ^ATOM "$pdb" | awk '
        FNR==NR {atoms[$0]++; next}
        (substr($0, 12, 20) in atoms) {
            print substr($0, 31, 8), substr($0, 39, 8), substr($0, 47, 8);
        }
    ' common_atoms.txt - > "${pdb}_coords.txt"
done

# Step 3: Compute RMSD and track maximum deviations
echo "Calculating RMSD..."
declare -A max_rmsd
declare -A max_coords
temp_rmsd_file="temp_rmsd.txt"
rm -f "$temp_rmsd_file"
for ((i = 0; i < ${#pdb_files[@]}; i++)); do
    for ((j = i + 1; j < ${#pdb_files[@]}; j++)); do
        paste "${pdb_files[i]}_coords.txt" "${pdb_files[j]}_coords.txt" | \
        awk '{
            x1 = $1; y1 = $2; z1 = $3;
            x2 = $4; y2 = $5; z2 = $6;
            rmsd = sqrt(($1-$4)^2 + ($2-$5)^2 + ($3-$6)^2);
            atom_id = NR;
            print atom_id, rmsd, x1, y1, z1, x2, y2, z2;
        }' >> "$temp_rmsd_file"
    done
done

# Step 4: Find maximum RMSD per atom
awk '{
    if (!($1 in max_rmsd) || $2 > max_rmsd[$1]) {
        max_rmsd[$1] = $2;
        max_coords[$1] = $3 " " $4 " " $5 " " $6 " " $7 " " $8;
    }
} END {
    for (a in max_rmsd) {
        print max_rmsd[a], max_coords[a];
    }
}' "$temp_rmsd_file" > rmsd_data.txt

# Step 5: Normalize RMSD for color mapping
echo "Normalizing RMSD..."
max_rmsd_value=$(awk '{if ($1 > max) max = $1} END {print max}' rmsd_data.txt)

# Color range normalization function
awk -v min_rmsd="$min_color_rmsd" -v max_rmsd="$max_color_rmsd" -v global_max_rmsd="$max_rmsd_value" '
function clamp(x, min, max) {
    return x < min ? min : (x > max ? max : x)
}

{
    # Normalize within the specified color range
    normalized = clamp(($1 - min_rmsd) / (max_rmsd - min_rmsd), 0, 1)
    
    print normalized, $2, $3, $4, $5, $6, $7
}' rmsd_data.txt > normalized_rmsd.txt

# Step 6: Generate .bild file
echo "Generating .bild file..."
echo ".comment RMSD Visualization (Color Range: $min_color_rmsd - $max_color_rmsd)" > "$output_bild"
while read rmsd x1 y1 z1 x2 y2 z2; do
    r=$(echo "$rmsd" | awk '{print $1^2}')
    g=$(echo "$rmsd" | awk '{print 1 - 4 * ($1 - 0.5)^2}')
    b=$(echo "$rmsd" | awk '{print (1 - $1)^2}')
    echo ".color $r $g $b" >> "$output_bild"
    echo ".cylinder $x1 $y1 $z1 $x2 $y2 $z2 $radius" >> "$output_bild"
done < normalized_rmsd.txt

# Clean up temporary files
rm -f "$temp_rmsd_file"
echo "Processing complete. Output saved to $output_bild"
