# MediBook product brief

## Company

MediBook provides online appointment booking for outpatient clinics. Patients book, view and manage visits without phoning the clinic.

## Users

| Role | Status | Description |
| --- | --- | --- |
| Patient | Live | Registers, books appointments and views their own bookings |
| Clinic staff | Planned | Manages clinic schedules and bookings for their clinic |
| Administrator | Planned | Manages clinics, staff accounts and platform settings |

## Main user journey

1. A patient signs up with a name, email address and password.
2. The patient signs in and receives a session token.
3. The patient views open appointment slots.
4. The patient selects a slot and submits a booking.
5. The service checks the session, validates the request, confirms the slot is still open and saves the appointment against that patient.
6. The patient views their appointments. Only their own bookings are returned.

## Capabilities

- Sign up, sign in and sign out.
- View open slots.
- Book a slot. A patient may hold several appointments; each slot can be booked by only one patient.
- View own appointment list and appointment details.
- Health endpoint and controlled error responses for invalid input.

## Data classification

Confidentiality (C): prevent unauthorised disclosure. Integrity (I): prevent unauthorised or incorrect changes. Availability (A): keep the service and data usable.

| Data | Why it matters | Priority |
| --- | --- | --- |
| Appointment records: ID, patient, slot, time, status | A booking alone reveals that a person is receiving care, where and when. Wrong owner or time breaks trust; loss prevents patients checking visits. | C, I, A |
| Patient profiles: name, email, account ID | Must stay private to the account; the link between a patient and their records must not be altered. | C, I |
| Password hashes and session tokens | Exposure enables account takeover. Sign-out must revoke the session. | C, I |
| Slots and booking state | Incorrect updates cause double bookings or show booked slots as open. | I, A |

MediBook does not collect symptoms, clinical history, diagnoses, date of birth, insurance or payment data. This data minimisation limits the impact of any disclosure.

## Critical assets

1. **Appointment data.** Disclosure reveals who receives care, where and when. Tampering or loss causes missed or misattributed visits.
2. **Patient profiles.** Unauthorised access or change exposes account information or corrupts the link between a patient and their records.
3. **Credentials and sessions.** Compromise lets an attacker act as a patient and reach both assets above.

Assets 1 and 2 are ranked by the harm of disclosure; asset 3 is the control that protects them both.

## Out of scope

| Item | Reason |
| --- | --- |
| Payments and insurance | External integrations and financial data are not needed for booking. |
| Staff and administrator portals | Additional roles expand the authorisation model; added after patient flows are proven. |
| AI intake assistant | Adds model integration and untrusted-input risk; planned after the core service is secured. |
| Cancellation and rescheduling | Additional state transitions; planned for a later release. |
| Real patient data | All environments use synthetic data. |

## Assumptions

- Synthetic data only; demo accounts use the reserved `example.com` domain.
- Slots are seeded by script until the staff portal exists.
- Patient identity always comes from authentication, never from a value supplied in a request.
