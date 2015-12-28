$LOAD_PATH << File.expand_path(File.dirname(__FILE__))

require 'rubygems'
require 'bundler'
require 'json'
Bundler.require(:default)

Dotenv.load

Geokit::Geocoders::MapboxGeocoder.key = ENV["MAPBOX_ACCESS_TOKEN"]
Geokit::Geocoders::GoogleGeocoder.api_key = ENV["GOOGLE_API_KEY"]
Geokit::Geocoders::provider_order =  [:mapbox, :google]
Mapbox.access_token = ENV["MAPBOX_ACCESS_TOKEN"]

require 'where_to_meet'
run WhereToMeet
