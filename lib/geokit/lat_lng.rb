module Geokit
  class LatLng

    def marshal_dump
      [@lat, @lng]
    end

    def marshal_load(array)
      @lat, @lng = array
    end
  end
end
