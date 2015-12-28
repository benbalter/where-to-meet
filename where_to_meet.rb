class WhereToMeet < Sinatra::Base
  extend Memoist

  set :assets_precompile, %w(application.js application.css)
  set :assets_prefix, %w(assets)
  set :assets_css_compressor, :sass
  set :assets_js_compressor, :uglifier
  register Sinatra::AssetPipeline

  use Rack::Session::Cookie, {
    :http_only => true,
    :secret    => ENV['SESSION_SECRET'] || SecureRandom.hex
  }

  configure :production do
     require 'rack-ssl-enforcer'
     use Rack::SslEnforcer
   end

  FOURSQUARE_API_VERSION = 20160101
  PARAMS = [
    :your_location,
    :you_profile,
    :friend_location,
    :friend_profile,
    :section,
    :foursquare
  ]
  MEMCACHE_OPTIONS = {
    :namespace  => "where_to_meet",
    :compress   => true,
    :expires_in => 60 * 60, # 1 HR cache
    :username => ENV["MEMCACHIER_USERNAME"],
    :password => ENV["MEMCACHIER_PASSWORD"],
    :failover => true,
    :socket_timeout => 1.5,
    :socket_failure_delay => 0.2
  }

  def logger
    Logger.new(STDOUT)
  end
  memoize :logger

  def cache
    Dalli::Client.new((ENV["MEMCACHIER_SERVERS"] || "localhost:11211").split(","), MEMCACHE_OPTIONS)
  end
  memoize :cache

  def foursquare_client
    Foursquare2::Client.new({
      client_id: ENV["FOURSQUARE_CLIENT_ID"],
      client_secret: ENV["FOURSQUARE_CLIENT_SECRET"],
      oauth_token: session[:oauth_token],
      api_version: FOURSQUARE_API_VERSION
    })
  end

  def oauth_client
    OAuth2::Client.new(ENV["FOURSQUARE_CLIENT_ID"], ENV["FOURSQUARE_CLIENT_SECRET"],
      :site => 'https://foursquare.com',
      :token_url => "/oauth2/access_token",
      :authorize_url => "/oauth2/authenticate?response_type=code",
      :parse_json => true
    )
  end
  memoize :oauth_client

  def geocode(address)
    cache_key = "geocode:#{address}"
    unless response = cache.get(cache_key)
      response = Geokit::Geocoders::MultiGeocoder.geocode(address)
      cache.set(cache_key, response)
    end
    response
  end

  def you
    geocode params["your_location"]
  end

  def friend
    geocode params["friend_location"]
  end

  def midpoint
    return unless params["your_location"] && params["friend_location"]
    you.midpoint_to friend
  end

  def query(midpoint, section)
    parts = [midpoint, section, session[:oauth_token]].compact.join(":")
    cache_key = "foursquare:" + Digest::MD5.hexdigest(parts)
    unless response = cache.get(cache_key)
      response = foursquare_client.explore_venues({
        ll: midpoint,
        section: section,
        limit: 10
      })
      cache.set(cache_key, response)
    end
    response
  end

  def venues
    response = query(midpoint, params["section"])
    response.groups.find { |g| g.name == "recommended" }.items
  end

  def feature(lat, lon, properties)
    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    point = factory.point(lon, lat)
    RGeo::GeoJSON::Feature.new point, nil, properties
  end

  def geojson_url
    Addressable::URI.new({
      :scheme => request.scheme,
      :host   => request.host,
      :port   => (request.port if settings.development?),
      :path   => "/venues.geojson",
      :query_values => PARAMS.map { |p| [p, params[p.to_s]] }.to_h
    })
  end

  def venues_url
    query_values = PARAMS.reject { |p| p == :foursquare }.map { |p| [p, session[p]] }.to_h
    Addressable::URI.new({
      :scheme => request.scheme,
      :host   => request.host,
      :port   => (request.port if settings.development?),
      :path   => "/venues",
      :query_values => query_values
    })
  end

  def factory
    RGeo::Geographic.spherical_factory(srid: 4326)
  end
  memoize :factory

  def bounding_box
    points = venues.map { |i| factory.point(i.venue.location.lng, i.venue.location.lat) }
    points.push factory.point(you.lng, you.lat)
    points.push factory.point(friend.lng, friend.lat)
    multi_points = factory.multi_point(points)
    RGeo::Cartesian::BoundingBox.create_from_geometry(multi_points)
  end

  def callback_url
    Addressable::URI.new({
        :scheme => request.scheme,
        :host   => request.host,
        :port   => (request.port if settings.development?),
        :path   => "/oauth2/callback"
      })
  end
  memoize :callback_url

  helpers do
    def time_to(from, to)
      from_parts = if from == :you
        you
      else
        friend
      end

      parts = [from_parts.lat,from_parts.lng,to["lat"],to["lng"]].join(":")
      cache_key = "time_to:" + Digest::MD5.hexdigest(parts)

      cached = cache.get cache_key
      return cached.to_i if cached

      profile = params["#{from}_profile"]

      response = Mapbox::Directions.directions([{
        "latitude"  => from_parts.lat,
        "longitude" => from_parts.lng
      }, {
        "latitude"  => to["lat"],
        "longitude" => to["lng"]
      }], "mapbox.#{profile}").first

      return if response["routes"].empty?
      time = response["routes"].first["duration"]
      cache.set cache_key, time.to_i

      time
    end
    memoize :time_to

    def time_to_in_words(from, to)
      time = time_to from, to
      time = time.to_f / 60
      time = time.round(0)
      "<span class=\"minutes\">#{time}</span> #{time == 1 ? "minute" : "minutes"}"
    end

    def profile_dropdown(type)
      "<select name=\"#{type}_profile\" class=\"form-control\">
        <option value=\"walking\">walking</option>
        <option value=\"cycling\">biking</option>
        <option value=\"driving\">driving</option>
      </select>"
    end
  end

  get "/oauth2/callback" do
    session[:oauth_token] = oauth_client.auth_code.get_token(params[:code],
      :redirect_uri => callback_url
    ).token
    redirect venues_url
  end

  get "/logout" do
    session[:oauth_token] = nil
    redirect "/"
  end

  get "/" do
    erb :index
  end

  get "/venues" do
    if params["foursquare"] == "on" && session[:oauth_token].nil?
      PARAMS.each { |param| session[param] = params[param.to_s] }
      halt redirect oauth_client.auth_code.authorize_url(:redirect_uri => callback_url)
    end

    response = query(midpoint, params["section"])

    erb :venues, locals: {
      location: response.headerLocation,
      venues: venues,
      midpoint: [midpoint.to_lat_lng.to_a[1], midpoint.to_lat_lng.to_a[0]].join(","),
      you: you.to_lat_lng.ll,
      friend: friend.to_lat_lng.ll,
      geojson_url: geojson_url,
      bounding_box: bounding_box
    }
  end

  get "/venues.geojson" do
    features = venues.map do |item|
      venue = item.venue
      location = venue.location
      properties = { name: venue.name, address: location.formattedAddress.first, "marker-symbol": "bar" }
      feature location.lat, location.lng, properties
    end

    features.push feature(*you.to_lat_lng.to_a, {
      name: "You",
      "marker-color": "#fff",
      "marker-symbol": "star"
    })
    features.push feature(*friend.to_lat_lng.to_a, {
      name: "Your friend",
      "marker-color": "#bbb",
      "marker-symbol": "star"
    })

    feature_collection = RGeo::GeoJSON::FeatureCollection.new features
    RGeo::GeoJSON.encode(feature_collection).to_json
  end

  get '/application.js' do
    coffee :application
  end
end
