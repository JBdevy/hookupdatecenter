MainActor.assumeIsolated {
for overlap in [false, true] {
 for scale in [1.0, 500.0, 81920.0] {
  var song = Project.empty(name: "Markers").songs[0]
  let origin = 10000.0 * scale, start = 10000.0
  song.parts = [Part(id: UUID(), name: "Region", startTime: start, endTime: start + 700 / scale, color: 0xffaa00)]
  if overlap { song.parts.append(Part(id: UUID(), name: "Overlap", startTime: start + 10 / scale, endTime: start + 300 / scale, color: 0xaa44ff)) }
  song.markers = [TimelineMarker(id: UUID(), name: "FIRST", position: start + 40 / scale, color: 0x54ff93), TimelineMarker(id: UUID(), name: "SECOND", position: start + 240 / scale, color: 0x54ff93)]
  let y = CGFloat(RegionLanes(parts: song.parts).count) * 16, height = y + 39
  let extent = start + 800 / scale, width = extent * scale
  let key = TimelineRenderKey()
  let fixture = ZStack(alignment: .topLeading) {
   TimelineHeader(visibleRect: CGRect(x: origin, y: 0, width: 640, height: height), song: song, renderKey: key, extent: extent).frame(width: width, height: height)
   TimelineMarkerLane(visibleRect: CGRect(x: origin, y: 0, width: 640, height: 16), song: song, renderKey: key, extent: extent).frame(width: width, height: 16).clipped().offset(y: y)
  }.frame(width: width, height: height, alignment: .topLeading).offset(x: -origin).frame(width: 640, height: height, alignment: .topLeading).clipped()
  let renderer = ImageRenderer(content: fixture); renderer.scale = 2
  let image = renderer.cgImage!, bitmap = NSBitmapImageRep(cgImage: image)
  func green(_ x: Int, _ yy: Int) -> Bool { let c = bitmap.colorAt(x: x*2,y: yy*2)!.usingColorSpace(.sRGB)!; return c.greenComponent > 0.7 && c.redComponent < 0.5 }
  precondition(green(42,Int(y)+4), "flag must be in marker lane")
  precondition(!green(42,Int(y)-4), "flag cannot overlap region lane")
  precondition(!green(42,Int(y)+20), "flag cannot fall into ruler lane")
  print("MARKER_FLAG_LANE_OK overlap=\(overlap) scale=\(scale)")
 }
}
}
