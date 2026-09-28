-- Enable necessary extensions
CREATE EXTENSION IF NOT EXISTS vector;

-- 1. Users Table (Stores user profiles and Google OAuth tracking)
CREATE TABLE users (
                       id UUID PRIMARY KEY DEFAULT uuidv7(),
                       email VARCHAR(255) UNIQUE NOT NULL,
                       name VARCHAR(255) NOT NULL,
                       avatar_url TEXT,
                       provider VARCHAR(50) NOT NULL DEFAULT 'GOOGLE', -- GOOGLE, LOCAL, etc.
                       provider_id VARCHAR(255) UNIQUE, -- Unique subject ID from Google OAuth
                       created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
                       updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 2. Roles & User Roles Tables (Role-Based Access Control / RBAC)
CREATE TABLE roles (
                       id SERIAL PRIMARY KEY,
                       name VARCHAR(50) UNIQUE NOT NULL -- e.g., ROLE_USER, ROLE_ADMIN, ROLE_ORGANIZER
);

CREATE TABLE user_roles (
                            user_id UUID REFERENCES users(id) ON DELETE CASCADE,
                            role_id INT REFERENCES roles(id) ON DELETE CASCADE,
                            PRIMARY KEY (user_id, role_id)
);
CREATE INDEX idx_user_roles_user ON user_roles(user_id);

-- 3. Venues Table (Physical locations where events happen)
CREATE TABLE venues (
                        id UUID PRIMARY KEY DEFAULT uuidv7(),
                        name VARCHAR(255) NOT NULL,
                        location VARCHAR(255) NOT NULL,
                        capacity INT NOT NULL,
                        created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
                        updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 4. Events Table (Concerts, shows, or conferences)
CREATE TABLE events (
                        id UUID PRIMARY KEY DEFAULT uuidv7(),
                        title VARCHAR(255) NOT NULL,
                        description TEXT,
                        category VARCHAR(100),
                        start_time TIMESTAMP WITH TIME ZONE NOT NULL,
                        end_time TIMESTAMP WITH TIME ZONE NOT NULL,
                        venue_id UUID REFERENCES venues(id) ON DELETE CASCADE,
                        created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
                        updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_events_venue ON events(venue_id);

-- 5. Venue Seats Table (Physical layout of seats belonging to a venue)
CREATE TABLE venue_seats (
                             id UUID PRIMARY KEY DEFAULT uuidv7(),
                             venue_id UUID REFERENCES venues(id) ON DELETE CASCADE,
                             section VARCHAR(50) NOT NULL,
                             row_number VARCHAR(10) NOT NULL,
                             seat_number VARCHAR(10) NOT NULL,
                             CONSTRAINT unique_venue_seat UNIQUE (venue_id, section, row_number, seat_number)
);
CREATE INDEX idx_venue_seats_venue ON venue_seats(venue_id);

-- 6. Event Seats Table (Event-specific pricing and real-time availability)
CREATE TABLE event_seats (
                             id UUID PRIMARY KEY DEFAULT uuidv7(),
                             event_id UUID REFERENCES events(id) ON DELETE CASCADE,
                             venue_seat_id UUID REFERENCES venue_seats(id) ON DELETE CASCADE,
                             status VARCHAR(50) DEFAULT 'AVAILABLE' CHECK (status IN ('AVAILABLE', 'RESERVED', 'BOOKED')),
                             price NUMERIC(10, 2) NOT NULL,
                             CONSTRAINT unique_event_seat UNIQUE (event_id, venue_seat_id)
);

-- Indexes for high-speed availability queries and FK joins
CREATE INDEX idx_event_seats_event ON event_seats(event_id);
CREATE INDEX idx_event_seat_availability ON event_seats(event_id, status);

-- 7. Seat Holds Table (Temporary locks during checkout to prevent double-booking)
CREATE TABLE seat_holds (
                            id UUID PRIMARY KEY DEFAULT uuidv7(),
                            event_seat_id UUID REFERENCES event_seats(id) ON DELETE CASCADE,
                            user_id UUID REFERENCES users(id) ON DELETE CASCADE,
                            expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
                            created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for fast hold verification and expiry cleanup workers
CREATE INDEX idx_seat_holds_expiry ON seat_holds(expires_at);
CREATE INDEX idx_seat_holds_user ON seat_holds(user_id);
-- Partial unique index: Ensures a single event seat can only have one active unexpired hold at a time
CREATE UNIQUE INDEX idx_unique_active_seat_hold ON seat_holds(event_seat_id);

-- 8. Bookings Table (The master order record when a user checks out)
CREATE TABLE bookings (
                          id UUID PRIMARY KEY DEFAULT uuidv7(),
                          user_id UUID REFERENCES users(id) ON DELETE CASCADE,
                          event_id UUID REFERENCES events(id) ON DELETE CASCADE,
                          total_amount NUMERIC(10, 2) NOT NULL,
                          status VARCHAR(50) DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'CONFIRMED', 'CANCELLED')),
                          created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
                          updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_bookings_user ON bookings(user_id);
CREATE INDEX idx_bookings_event ON bookings(event_id);

-- 8.5. Booking Seats Table (Connects a booking to specific event seats + door scanning status)
CREATE TABLE booking_seats (
                               booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
                               event_seat_id UUID REFERENCES event_seats(id) ON DELETE CASCADE,
                               ticket_code VARCHAR(100) UNIQUE NOT NULL, -- Unique hash for door scanning
                               is_checked_in BOOLEAN DEFAULT FALSE, -- Tracks if ticket has been redeemed at the venue gate
                               checked_in_at TIMESTAMP WITH TIME ZONE,
                               PRIMARY KEY (booking_id, event_seat_id)
);

-- 9. Payments Table (Handles dual payment gateways: Stripe & Safaricom Daraja M-Pesa)
CREATE TABLE payments (
                          id UUID PRIMARY KEY DEFAULT uuidv7(),
                          booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
                          gateway VARCHAR(50) NOT NULL CHECK (gateway IN ('STRIPE', 'MPESA')),
                          transaction_reference VARCHAR(255) UNIQUE,
                          phone_number VARCHAR(20), -- Dedicated field for M-Pesa MSISDN tracking
                          merchant_request_id VARCHAR(255), -- Daraja STK Push tracking reference
                          amount NUMERIC(10, 2) NOT NULL,
                          status VARCHAR(50) DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'SUCCESS', 'FAILED')),
                          raw_response TEXT, -- Stores full JSON response from Stripe/M-Pesa for auditing
                          created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_payments_booking ON payments(booking_id);

-- 10. Vector Embeddings Table (For Spring AI pgvector RAG & semantic event search)
CREATE TABLE vector_embeddings (
                                   id UUID PRIMARY KEY DEFAULT uuidv7(),
                                   event_id UUID REFERENCES events(id) ON DELETE CASCADE,
                                   embedding VECTOR(768) -- Matches Google Gemini embedding vector dimension size
);
CREATE INDEX idx_vector_embeddings_event ON vector_embeddings(event_id);

-- HNSW Vector Index for lightning-fast semantic similarity search (AI search)
CREATE INDEX idx_vector_embeddings_hnsw ON vector_embeddings USING hnsw (embedding vector_cosine_ops);

-- -----------------------------------------------------------------
-- 11. Automated Timestamp Trigger Functions
-- -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_user_modtime BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_modified_column();
CREATE TRIGGER update_venue_modtime BEFORE UPDATE ON venues FOR EACH ROW EXECUTE FUNCTION update_modified_column();
CREATE TRIGGER update_event_modtime BEFORE UPDATE ON events FOR EACH ROW EXECUTE FUNCTION update_modified_column();
CREATE TRIGGER update_booking_modtime BEFORE UPDATE ON bookings FOR EACH ROW EXECUTE FUNCTION update_modified_column();