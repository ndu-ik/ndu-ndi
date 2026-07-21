#!/bin/bash

# Clone the repository without any submodules (non-recursive)
git clone --no-recurse-submodules https://github.com/ndu-ik/ndu-ndi.git

# Check if clone was successful
if [ $? -eq 0 ]; then
    # Change into the directory
    cd ndu-ndi || exit
    
    # Run the fluidwall.sh script with set-install parameter
    ./fluidwall.sh set-install
else
    echo "Failed to clone repository"
    exit 1
fi