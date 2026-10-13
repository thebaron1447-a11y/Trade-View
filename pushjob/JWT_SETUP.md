# JWT setup for the push job

A scheduled job cannot log in through a browser, so it uses the OAuth 2.0 JWT bearer flow:
it signs a short-lived token with a private key, and Salesforce verifies it with the matching
certificate stored on an External Client App. New Connected Apps can no longer be created by
default (Spring '26), so this uses an External Client App.

Setup labels below may differ slightly by release; the settings themselves are the same.

## 1. Create the key and certificate

```powershell
cd pushjob
python generate_keys.py
```

This creates `keys\server.key` (secret, never commit it; `keys/` is git-ignored) and `keys\server.crt`.

## 2. Create the External Client App

1. Setup > **External Client App Manager** > **New External Client App**.
2. Name: `Trade Import Push Job`. Contact email: yours. Distribution state: **Local**.
3. Expand **API (Enable OAuth Settings)** and check **Enable OAuth**.
   - Callback URL: `http://localhost:1717/OauthRedirect` (required by the form, not used by JWT).
   - OAuth scopes: **Manage user data via APIs (api)** and **Perform requests at any time (refresh_token, offline_access)**.
   - Under Flow Enablement, check **Enable JWT Bearer Flow** and upload `keys\server.crt`.
4. Create.
5. On the app's **Policies** tab, edit: set **Permitted Users** to **Admin approved users are pre-authorized**,
   and under **Select Permission Sets** add **Trade Import Admin** (or Trade Import Integration for a dedicated user).
   Save.
6. On the **Settings** tab, open **OAuth Settings > Consumer Key and Secret** and copy the **Consumer Key**.

Allow up to 10 minutes for a new app to become active.

## 3. Run with JWT

```powershell
$env:SF_CLIENT_ID = "<consumer key>"
$env:SF_USERNAME = "gregory.baron.f2cac6700e9c@agentforce.com"
$env:SF_PRIVATE_KEY_FILE = "keys\server.key"
python push_job.py --lake ..\datalake --once --auth jwt
```

`SF_LOGIN_URL` defaults to `https://login.salesforce.com`; use `https://test.salesforce.com` for a sandbox.

## Production notes

- Run as a dedicated integration user with only the **Trade Import Integration** permission set
  (it can call the endpoint, create batches and staging rows, and read mapping profiles).
  That user also needs read access to the firm Accounts referenced by mapping profiles.
- Common errors: `user hasn't approved this consumer` means the user's permission set is not on the app's
  policy; `invalid_grant` with an `audience` message means `SF_LOGIN_URL` does not match the org type.
