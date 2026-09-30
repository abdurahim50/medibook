# MediBook company brief

## Company

MediBook is a fictional clinic appointment booking service, built by Abdurahim Yongho as a training company for an independent security portfolio.

## Users

The initial user role is patient. Each synthetic patient has a separate account and can access only their own appointments. Clinic staff and administrator roles are future possibilities and are not part of the first working slice.

## Main user journey

1. A patient signs up using a fictional name, an example email address and a training password.
2. The patient signs in, and the application establishes an authenticated session.
3. The patient views a small, seeded set of available appointment slots.
4. The patient selects a slot and submits a booking request.
5. The application checks authentication, validates the request, confirms that the slot remains available and saves an appointment associated with that patient.
6. The patient opens their appointments page and sees their booked appointment. The backend checks ownership before returning appointment data.

This journey describes planned behavior. It has not yet been implemented or demonstrated.

## What users can do

- Sign up, sign in and sign out using synthetic accounts.
- View seeded available slots.
- Book one available slot per booking request. A patient may hold several appointments, but each slot can be booked by only one patient.
- View their own appointment list and appointment details.

The application will also expose a health endpoint and handle bad input with a controlled error. Double booking of a slot should be rejected. Cancellation, rescheduling and staff actions are excluded from the first version.

## Data that must be protected

Confidentiality (C) means preventing unauthorized disclosure. Integrity (I) means preventing unauthorized or incorrect changes. Availability (A) means keeping the service and data usable when needed.

| Data | Why protection matters | CIA priorities |
| --- | --- | --- |
| Appointment records: appointment ID, patient ID, slot, time and status | Another patient must not see a booking. Changing its owner or time would break trust, and losing access prevents the patient from checking the booking. | C, I, A |
| Synthetic patient profiles: fictional name, example email and account ID | Profiles must remain private to the correct account, and identity associations must not be altered incorrectly. The training design models a sensitive patient context. | C, I |
| Password hashes and active session identifiers | Exposure can support account takeover. Session identity must remain trustworthy, and sign-out must invalidate the session as designed. Plaintext passwords must not be stored. | C, I |
| Available slots and their booking state | Incorrect updates could cause duplicate bookings or show a booked slot as available. Patients need usable access to scheduling information. | I, A |

The first version does not collect symptoms, clinical histories, diagnoses, insurance details or payment data. This is a deliberate data-minimisation choice that reduces the impact of any disclosure.

## Top 3 assets

1. **Appointment data:** in a clinic context, a booking alone reveals that a person is receiving care, where and when. Disclosure, tampering or loss would expose that fact, attach appointments to the wrong patient or prevent patients from checking their bookings.
2. **Patient profiles:** unauthorized access or alteration would expose account information or corrupt the link between a patient and their records.
3. **Authentication credentials and sessions:** compromise could let an attacker impersonate a patient and access or change the assets associated with that account.

Assets 1 and 2 are ranked by the harm their disclosure causes; asset 3 is the control that protects both, so its compromise leads directly to the first two.

## Out of scope (deliberately)

| Exclusion | Why it is excluded now |
| --- | --- |
| Payments and insurance processing | They add external integrations and sensitive financial workflows that are unnecessary to demonstrate one booking journey. |
| Real patient data and real clinical operation | This is a training project. Synthetic data lets security failures be reproduced without involving actual patients. |
| Staff/admin portal | Additional roles and permissions would expand the authorization model before the patient workflow is proven. |
| AI intake assistant | It adds model integration, untrusted-input handling and data-access risks. It will be considered in a later phase after the core booking feature works. |
| Cancellation and rescheduling | They add more state transitions and tests. The first version focuses on creating and viewing one booking. |
| Cloud deployment | Local startup and security checks must work first. Deployment will follow a documented cost and cleanup plan. |

## Assumptions

- Synthetic data only, including fictional names and email addresses under `example.com`.
- Local-first development on Ubuntu/WSL2 or an equivalent Linux environment.
- Training use only; no clinical advice or real clinic operations.
- Appointment slots are seeded locally; no staff interface is needed to create them initially.
- Patient identity comes from authentication, not a patient ID supplied in a request body or by an AI assistant.
- Booking creation and slot assignment will be designed to avoid duplicate booking.
- The repository starts private. Reviewer access must be arranged and verified before review submission.
- Later AI and AWS work is planned, not evidence of a completed feature or deployment.