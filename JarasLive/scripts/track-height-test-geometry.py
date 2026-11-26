#!/usr/bin/env python3
"""Supply shared row geometry to isolated native scroll-view test fixtures."""
from pathlib import Path
import sys
models = Path('Application/Project/ProjectModels.swift').read_text()
geometry = models[models.index('public enum TrackHeightGeometry'):models.index('public struct TrackLinkOriginal')]
Path(sys.argv[1]).write_text('import Foundation\n' + geometry)
