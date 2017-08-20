Pod::Spec.new do |s|
  s.name             = "ILABReverseVideoExporter"
  s.version          = "0.1.4"
  s.summary          = "Utility class for exporting reversed AVAssets.  Based on CSVideoReverse by Chris Sung."
  s.homepage         = "https://github.com/interfacelab/ILABReverseVideoExporter"
  s.license          = { :type => "MIT", :file => "LICENSE" }
  s.author           = { "Jon Gilkison" => "jon@interfacelab.com" }
  s.source           = { :git => "https://github.com/interfacelab/ILABReverseVideoExporter.git", :tag => s.version.to_s }
  s.ios.deployment_target = '10.0'
  s.requires_arc = true
  s.source_files = 'Source'
end
