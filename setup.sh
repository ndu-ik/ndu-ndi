#!/bin/bash

# 1. Clone without checking out any files or submodules initially
git clone --no-checkout --no-recurse-submodules https://github.com/ndu-ik/ndu-ndi.git ndu-ndi

# Check if clone was successful
if [ $? -eq 0 ]; then
    # Change into the directory
    cd ndu-ndi || exit
    
    # 2. Initialize sparse-checkout in cone mode
    git sparse-checkout init --cone
    
    # 3. Explicitly tell git to only check out files at the root level (no subfolders)
    git sparse-checkout set ""
    
    # 4. Checkout the repository with the sparse rules applied
    git checkout
     
    # 5. Run the fluidwall.sh script with set-install parameter
    ./fluidwall.sh set-install
else
    echo "Failed to clone repository"
    exit 1
fi