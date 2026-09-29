# Waits for an App Store Connect upload to finish processing and reach TestFlight.
# Usage: ruby fork/asc_wait.rb <delivery-uuid> <build-number>
# Env: ASC_ISSUER_ID (required), ASC_KEY_ID (default JTM5DPS5W7), BUNDLE_ID.
require "openssl"
require "base64"
require "json"
require "net/http"

DELIVERY, VERSION = ARGV
abort "usage: asc_wait.rb <delivery-uuid> <build-number>" unless DELIVERY && VERSION
KEY_ID = ENV.fetch("ASC_KEY_ID", "JTM5DPS5W7")
ISSUER = ENV.fetch("ASC_ISSUER_ID") { abort "ASC_ISSUER_ID is not set" }
BUNDLE = ENV.fetch("BUNDLE_ID", "com.mitchmalone.blinkshell")
KEY = OpenSSL::PKey.read(File.read(File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{KEY_ID}.p8")))

def b64(s) = Base64.urlsafe_encode64(s, padding: false)

# App Store Connect wants an ES256 JWT with a raw r||s signature.
def token
  now = Time.now.to_i
  input = "#{b64({ alg: "ES256", kid: KEY_ID, typ: "JWT" }.to_json)}.#{b64({ iss: ISSUER, iat: now, exp: now + 600, aud: "appstoreconnect-v1" }.to_json)}"
  der = KEY.sign(OpenSSL::Digest::SHA256.new, input)
  raw = OpenSSL::ASN1.decode(der).value.map { |i| i.value.to_s(2).rjust(32, "\x00")[-32, 32] }.join
  "#{input}.#{b64(raw)}"
end

def get(path)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{token}"
  JSON.parse(Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }.body)
end

app = get("/v1/apps?filter[bundleId]=#{BUNDLE}")["data"]&.first or abort "no app for #{BUNDLE}"
last = nil
loop do
  upload = get("/v1/buildUploads/#{DELIVERY}").dig("data", "attributes", "state") || {}
  errors = (upload["errors"] || []).map { |e| e["description"] || e.to_s }
  builds = get("/v1/builds?filter[app]=#{app["id"]}&filter[version]=#{VERSION}&include=buildBetaDetail")
  build = builds["data"]&.first
  detail = (builds["included"] || []).find { |i| i["type"] == "buildBetaDetails" }
  internal = detail&.dig("attributes", "internalBuildState")
  processing = build&.dig("attributes", "processingState")
  line = "upload=#{upload["state"]} processing=#{processing || "-"} testflight=#{internal || "-"}#{errors.empty? ? "" : " errors=#{errors.join("; ")}"}"
  puts line if line != last
  last = line
  exit 0 if %w[IN_BETA_TESTING READY_FOR_BETA_TESTING].include?(internal)
  exit 1 if upload["state"] == "FAILED" || %w[INVALID FAILED].include?(processing) || internal == "MISSING_EXPORT_COMPLIANCE"
  sleep 60
end
