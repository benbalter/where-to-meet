# Where to Meet

*An app to answer the simple question, where's the best place for two people to meet?*

## How it works

1. Enter two addresses and select the mode of transportation for both you and your friend
2. Select what you're looking to do
3. Where to Meet finds the top-rated locations equidistant to both of you, listing the travel times for each

## How it works under the hood

* MapBox geolocation and directions API
* MapBox GL
* Geokit for some spatial calculations

## Running locally

1. `script/bootstrap`
2. `script/server`
3. Open `localhost:9292` in your browser

Note: You'll need to have Memcache installed and running
