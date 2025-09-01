## Sampling
  - Sample more than 4 Directions
    - Diagonals 8
    - More - but the Input only has that much Detail and contains step functions so we cant interpolate between Pixels
## Lattice contruction
  - Neighbours Distance Threshhold
  - Dont enforce all neighbours, so they dont eliminate states but just make then increasingly unlikely?
  - Only Focus on the most cardinally aligned neighbours and disregard the rest, what about hexgrid?
  - Only take the closest N neighbours, what about hexgrid?
## Rule Extraction
  - Abandon discrete states and move to continous Input functions from which we can sample and interpolate as much as we want
  - Only do adjacency rules and ignore any rotation, so check support in any direction
  