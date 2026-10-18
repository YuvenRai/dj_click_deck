# dj_click_deck

## Run locally

Use the same username and Game Code on all three addresses:

- https://djdeck4.netlify.app/
- http://localhost:5500/ (Live Server connects directly to the cloud API)
- http://127.0.0.1:8765/ (run `Start-DJ-Click-Deck.cmd`; this local server
  forwards API requests to the cloud)

Deploy the latest site and API changes to Netlify before using `localhost:5500`;
its browser requests to the cloud API require the updated CORS configuration.
An internet connection is required for account and save operations.
