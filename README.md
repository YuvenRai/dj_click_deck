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

New accounts receive a one-time Recovery ID after creation. Save it privately;
it can reset the account's Game Code and is rotated after each successful
recovery. The API must be deployed with Recovery ID support for account
creation and recovery to work. Accounts created before that deployment do not
have a Recovery ID.
