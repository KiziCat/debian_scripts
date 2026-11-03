#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Configuration: Set to true to actually delete files, false for dry-run
DELETE_FILES=false

# Check if ImageMagick is installed
if ! command -v identify &> /dev/null; then
    echo "Error: ImageMagick is not installed. Please install it using your package manager."
    exit 1
fi

echo "Scanning for images where height > width..."
if [ "$DELETE_FILES" = false ]; then
    echo "[DRY RUN MODE] No files will be deleted. Change DELETE_FILES=true to enable deletion."
fi
echo "------------------------------------------------------------------"

# Find common image formats recursively in the current directory
find . -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" -o -iname "*.gif" \) | while read -r img; do
    # Extract width and height
    dimensions=$(identify -format "%w %h" "$img" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        read width height <<< "$dimensions"
        
        # Check if height is greater than width
        if [ "$height" -gt "$width" ]; then
            if [ "$DELETE_FILES" = true ]; then
                echo "Deleting: $img (${width}x${height})"
                rm "$img"
            else
                echo "[Found] $img (${width}x${height})"
            fi
        fi
    fi
done

echo "------------------------------------------------------------------"
echo "Scan complete."