# Phase 4c: cloud storage pull (Amazon S3)

Trade View can now take dealer files straight from a cloud storage folder. This makes the third intake route real,
alongside the push job and uploads in the app. See section 25 of the build log.

- An admin connects a folder once as a **Cloud Source**. It names the folder and the Named Credential that reaches
  it. The access key lives only in Salesforce Setup, never in code or records.
- Each dealer's files sit in a subfolder named with the dealer code, as in the data lake: `inbox/BARDER/…`,
  `inbox/LUMIERE/…`.
- **Recent Files → Cloud folders** shows each folder's last and next check. **Pull now** checks a folder at once. A
  **Check for new files** setting lets anyone working the queue choose how often: Manual only, every 15 minutes,
  hourly, every 4 hours, or daily at an hour.
- Files already taken are remembered by path and version, so each version is taken once. **The bucket is only ever
  read**, never changed, so the access key can be read-only.
- Each file still goes through the same intake as the other routes: the duplicate check, the 1 MB limit, mapping
  profiles, matching and Claude.
- Files outside a dealer folder, not CSV or text, or over 1 MB are refused with the reason. A file that fails to
  download is tried again on the next pull.
- Whoever clicks Pull now gets a bell for each file it takes.

Azure Blob and Google Cloud Storage plug in later through the same `CloudStorage` interface.

## 1. Validate and deploy (31 test classes, expect 219 tests)

```powershell
.\scripts\deploy.ps1 -DryRun
.\scripts\deploy.ps1
```

## 2. AWS: a bucket and a read-only key (about 10 minutes)

All of this is in the AWS console. Use a region near you; the steps use `ca-central-1` (Canada Central).

For Trade View the "data lake" is one S3 bucket laid out like the local `datalake` folder: `inbox/<DEALER CODE>/` per
dealer. There is no `processed/` folder in the bucket, because the pull never moves or deletes files; Salesforce
remembers what it has taken instead. Glue, Athena and Lake Formation are not needed.

0. **If the AWS account is new.** Turn on MFA for the root user (account menu → **Security credentials**), then do
   everything else signed in as an admin IAM user or through IAM Identity Center, not as root. In **Billing and Cost
   Management → Budgets**, create a **Zero spend budget** so you get an email if anything starts costing money.
1. **Create the bucket.** Go to S3 → **Create bucket**.
   - Bucket type: **General purpose**.
   - Name: something unique, lowercase, **with no dots**, for example `trade-view-demo-gb`. A dot breaks the HTTPS
     certificate for the URL Salesforce calls.
   - Region: `ca-central-1`.
   - Leave **Object Ownership** at *ACLs disabled*, **Block all public access** on, **Bucket Versioning** off and
     **Default encryption** at *SSE-S3*.
   - Click **Create bucket**.
2. **Upload the sample files.** Open the bucket → **Upload** → **Add folder**, and choose
   `C:\dev\trade-import-demo\datalake\samples\inbox`. The bucket then holds `inbox/BARDER/…`, `inbox/NORTHGATE/…`
   and so on. Click **Upload**. The roster file (`datalake\samples\roster`) is not in it. Push it as before, or upload
   that folder too and add a second Cloud Source with Folder `roster/` (the policy then needs `roster/*` as well).
3. **Create a user that can only read.** Go to IAM → **Users** → **Create user**.
   - Name: `trade-view-reader`.
   - Leave console access off.
   - Click **Next** → **Attach policies directly** → **Create policy** → **JSON**, and paste this, with your bucket
     name in both places:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       { "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::trade-view-demo-gb" },
       { "Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::trade-view-demo-gb/inbox/*" }
     ]
   }
   ```

   - Name the policy `TradeViewReadOnly`, create it, then attach it to the user and finish.
4. **Create the access key.** Open the user → **Security credentials** → **Create access key** → *Application
   running outside AWS*.
   - Copy the **Access key** and **Secret access key**. The secret is shown only once.
   - Paste them **only** into Salesforce in the next step. Never put them in a file, chat or commit.

## 3. Salesforce: connect the bucket (about 5 minutes)

1. **External Credential.** Setup → **Named Credentials** → **External Credentials** tab → **New**.
   - Label `Trade View S3`, Name `Trade_View_S3`.
   - Authentication Protocol **AWS Signature Version 4**.
   - Service `s3`, Region `ca-central-1`.
   - Save.
2. **Principal with the key.** On the External Credential → **Principals** → **New**.
   - Parameter Name `S3Reader`.
   - Paste the **Access Key** and **Access Secret**.
   - Save.
3. **Named Credential.** **Named Credentials** tab → **New**.
   - Label `Trade View S3`, Name `Trade_View_S3`.
   - URL `https://trade-view-demo-gb.s3.ca-central-1.amazonaws.com`, using your bucket name.
   - External Credential **Trade View S3**.
   - Leave **Generate Authorization Header** on.
   - Save.
4. **Let people use it.** Setup → **Permission Sets** → **New**, Label `Trade View S3 Access` → Save.
   - Open **External Credential Principal Access** → Edit → add **Trade_View_S3 - S3Reader** → Save.
   - **Manage Assignments**: assign it to yourself. Scheduled pulls run as whoever scheduled the sweeper, which is
     you. Also assign it to anyone who will click Pull now.
   - This permission set is made in Setup, not in the repo, because it points at a credential made in Setup.
5. **The Cloud Source.** App Launcher → **Cloud Sources** → **New**.
   - Source Name `Dealer drop`.
   - Provider **Amazon S3**.
   - Named Credential `Trade_View_S3`.
   - Folder `inbox/`.
   - Leave Source Firm blank (one subfolder per dealer).
   - Tick **Active**.
   - Pull Frequency **Manual only** for now.
   - Save.

## 4. Try it

Reset without pushing, so the files come from the bucket instead: `.\scripts\reset-demo-full.ps1 -NoPush`.
Then open Trade Review → **Recent Files**.

| Try | You should see |
|---|---|
| **Cloud folders** | *Dealer drop · inbox/*, *Not checked yet. Checked only when you click Pull now.* |
| **Pull now** | *Checking for new files now…*, then (without refreshing) the dealer files appear under Recent files and the folder shows *Last checked …: 8 new files taken, 1 already received.* (Barder's re-sent file has the same contents as the original). Bells follow as each file is matched |
| Pull now again | *No new files.* Nothing is taken twice |
| Change **Check for new files** to *Every 15 minutes* | The folder shows the next check time; within about 15 minutes of a new file being uploaded to the bucket, it is taken |
| Choose *Daily* | An **At** box appears; pick an hour |
| Upload a file to `inbox/` itself (not a dealer folder), then Pull now | It is refused: the Cloud File says to put it in a dealer folder |
| The **Cloud Sources** tab → *Dealer drop* | Every file taken, with its status and the batch it became |

If Pull now shows *Failed* with **403 AccessDenied**, check the key in the principal and the policy's bucket name. With
**404**, check the bucket name and region in the Named Credential URL. If the error mentions principal access or the
credential, the person (or the scheduler) needs the **Trade View S3 Access** permission set.

## 5. Optional: run the LWC tests on your computer

```powershell
npm run test:unit
```

65 Jest tests should pass.
