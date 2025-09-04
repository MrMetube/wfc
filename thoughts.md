## Lattice contruction
  - Dont enforce all neighbours, so they dont eliminate states but just make then increasingly unlikely?
  - Weigh neighbours in similar directions less than neighbours in sparse directions
  - Only Focus on the most cardinally aligned neighbours and disregard the rest, what about hexgrid?
  - Only take the closest N neighbours, what about hexgrid?
  - Use the perpendicular to the common edge instead of the vector between the centers? Shouldn't this only effect the edges where the center is adjusted to be inside the bounds of the grid?
  
## Rule Extraction
  - rotate and mirror input
  - Only do adjacency rules and ignore any rotation, so check support in any direction
  - Sample the 8 Diagonals