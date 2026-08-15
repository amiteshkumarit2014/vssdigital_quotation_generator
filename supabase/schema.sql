-- ============================================================
-- VSS Digital Quotation Generator — Supabase Schema
-- Run this in: Supabase Dashboard → SQL Editor → New query
-- Project: vssdigital_quotation_generator
-- This schema is completely independent from the VSS Power
-- (vsspower_quotation_generator) database. Do NOT run it
-- against the VSS Power Supabase project.
-- ============================================================

-- ============================================================
-- 0. EXTENSIONS
-- ============================================================
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- 1. SHARED FUNCTION: updated_at trigger
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 2. PROFILES (application users — extends Supabase auth.users)
-- ============================================================
CREATE TABLE IF NOT EXISTS profiles (
  id            UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name     TEXT,
  role          TEXT DEFAULT 'staff' CHECK (role IN ('admin','staff','sales')),
  is_active     BOOLEAN DEFAULT true,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_profiles_updated_at ON profiles;
CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Auto-create a profile row whenever a new auth user signs up
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email))
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS trg_on_auth_user_created ON auth.users;
CREATE TRIGGER trg_on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ============================================================
-- 3. COMPANY SETTINGS (VSS Digital company information)
-- ============================================================
CREATE TABLE IF NOT EXISTS company_settings (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_name          TEXT,
  tagline               TEXT,
  address               TEXT,
  city                  TEXT,
  state                 TEXT,
  country               TEXT,
  postcode              TEXT,
  phone                 TEXT,
  phone_alt             TEXT,
  email                 TEXT,
  website               TEXT,
  gstin                 TEXT,
  logo_url              TEXT,
  bank_details          TEXT,
  footer_text           TEXT,
  default_currency      TEXT DEFAULT 'INR',
  default_validity_days INTEGER DEFAULT 15,
  default_gst_rate      NUMERIC(5,2) DEFAULT 18,
  quotation_prefix      TEXT DEFAULT 'VSSD-Q',
  created_at            TIMESTAMPTZ DEFAULT now(),
  updated_at            TIMESTAMPTZ DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_company_settings_updated_at ON company_settings;
CREATE TRIGGER trg_company_settings_updated_at
  BEFORE UPDATE ON company_settings
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- 4. CUSTOMERS (client master)
-- ============================================================
CREATE TABLE IF NOT EXISTS customers (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_name   TEXT NOT NULL,
  contact_person TEXT,
  email          TEXT,
  phone          TEXT,
  address        TEXT,
  city           TEXT,
  state          TEXT,
  country        TEXT DEFAULT 'India',
  postcode       TEXT,
  gstin          TEXT,
  website        TEXT,
  industry       TEXT,
  notes          TEXT,
  is_active      BOOLEAN DEFAULT true,
  created_at     TIMESTAMPTZ DEFAULT now(),
  updated_at     TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_customers_company_name ON customers (lower(company_name));
CREATE INDEX IF NOT EXISTS idx_customers_is_active ON customers (is_active);

DROP TRIGGER IF EXISTS trg_customers_updated_at ON customers;
CREATE TRIGGER trg_customers_updated_at
  BEFORE UPDATE ON customers
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- 5. SERVICE CATEGORIES
-- ============================================================
CREATE TABLE IF NOT EXISTS service_categories (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT UNIQUE NOT NULL,
  description   TEXT,
  sort_order    INTEGER DEFAULT 0,
  is_active     BOOLEAN DEFAULT true,
  created_at    TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- 6. SERVICES (service master)
-- ============================================================
CREATE TABLE IF NOT EXISTS services (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id        UUID REFERENCES service_categories(id) ON DELETE SET NULL,
  name               TEXT NOT NULL,
  description        TEXT,
  default_price      NUMERIC(12,2) DEFAULT 0 CHECK (default_price >= 0),
  billing_frequency  TEXT DEFAULT 'One Time' CHECK (billing_frequency IN ('One Time','Monthly','Quarterly','Half-Yearly','Yearly')),
  unit               TEXT DEFAULT 'Project',
  tax_rate           NUMERIC(5,2) DEFAULT 18,
  is_active          BOOLEAN DEFAULT true,
  created_at         TIMESTAMPTZ DEFAULT now(),
  updated_at         TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_services_category_id ON services (category_id);
CREATE INDEX IF NOT EXISTS idx_services_is_active ON services (is_active);

DROP TRIGGER IF EXISTS trg_services_updated_at ON services;
CREATE TRIGGER trg_services_updated_at
  BEFORE UPDATE ON services
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- 7. QUOTATION SEQUENCES (safe, concurrency-proof numbering)
-- ============================================================
CREATE TABLE IF NOT EXISTS quotation_sequences (
  prefix        TEXT NOT NULL,
  year          INTEGER NOT NULL,
  last_number   INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (prefix, year)
);

-- Atomically reserves and returns the next quotation number,
-- e.g. VSSD-Q-2026-0001. Safe under concurrent calls because the
-- INSERT ... ON CONFLICT DO UPDATE takes a row lock on the
-- (prefix, year) row for the duration of the transaction.
CREATE OR REPLACE FUNCTION get_next_quotation_number(p_prefix TEXT DEFAULT 'VSSD-Q')
RETURNS TEXT AS $$
DECLARE
  v_year INTEGER := EXTRACT(YEAR FROM now())::INTEGER;
  v_seq  INTEGER;
BEGIN
  INSERT INTO quotation_sequences (prefix, year, last_number)
  VALUES (p_prefix, v_year, 1)
  ON CONFLICT (prefix, year)
  DO UPDATE SET last_number = quotation_sequences.last_number + 1
  RETURNING last_number INTO v_seq;

  RETURN p_prefix || '-' || v_year || '-' || LPAD(v_seq::TEXT, 4, '0');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 8. QUOTATIONS (header)
-- ============================================================
CREATE TABLE IF NOT EXISTS quotations (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_number      TEXT UNIQUE NOT NULL,
  customer_id           UUID REFERENCES customers(id) ON DELETE SET NULL,
  project_name          TEXT,
  client_reference       TEXT,
  account_manager       TEXT,
  quotation_date        DATE NOT NULL DEFAULT CURRENT_DATE,
  valid_until           DATE,
  status                TEXT DEFAULT 'Draft' CHECK (status IN ('Draft','Sent','Accepted','Rejected','Expired','Cancelled')),
  currency              TEXT DEFAULT 'INR',
  tax_type              TEXT DEFAULT 'CGST_SGST' CHECK (tax_type IN ('CGST_SGST','IGST','NONE')),
  gst_rate              NUMERIC(5,2) DEFAULT 18,
  subtotal              NUMERIC(12,2) DEFAULT 0 CHECK (subtotal >= 0),
  overall_discount_pct  NUMERIC(5,2) DEFAULT 0 CHECK (overall_discount_pct >= 0 AND overall_discount_pct <= 100),
  overall_discount_amt  NUMERIC(12,2) DEFAULT 0,
  taxable_amount        NUMERIC(12,2) DEFAULT 0,
  cgst_amount           NUMERIC(12,2) DEFAULT 0,
  sgst_amount           NUMERIC(12,2) DEFAULT 0,
  igst_amount           NUMERIC(12,2) DEFAULT 0,
  total_amount          NUMERIC(12,2) DEFAULT 0,
  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at            TIMESTAMPTZ DEFAULT now(),
  updated_at            TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_quotations_customer_id    ON quotations (customer_id);
CREATE INDEX IF NOT EXISTS idx_quotations_status         ON quotations (status);
CREATE INDEX IF NOT EXISTS idx_quotations_quotation_date ON quotations (quotation_date);
CREATE INDEX IF NOT EXISTS idx_quotations_number         ON quotations (quotation_number);

DROP TRIGGER IF EXISTS trg_quotations_updated_at ON quotations;
CREATE TRIGGER trg_quotations_updated_at
  BEFORE UPDATE ON quotations
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- 9. QUOTATION ITEMS
-- ============================================================
CREATE TABLE IF NOT EXISTS quotation_items (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id       UUID NOT NULL REFERENCES quotations(id) ON DELETE CASCADE,
  service_id         UUID REFERENCES services(id) ON DELETE SET NULL,
  category_name      TEXT,
  service_name       TEXT NOT NULL,
  description        TEXT,
  billing_frequency  TEXT DEFAULT 'One Time' CHECK (billing_frequency IN ('One Time','Monthly','Quarterly','Half-Yearly','Yearly')),
  duration           TEXT,
  quantity           NUMERIC(12,2) DEFAULT 1 CHECK (quantity >= 0),
  unit               TEXT DEFAULT 'Project',
  unit_price         NUMERIC(12,2) DEFAULT 0 CHECK (unit_price >= 0),
  discount_pct       NUMERIC(5,2) DEFAULT 0 CHECK (discount_pct >= 0 AND discount_pct <= 100),
  tax_pct            NUMERIC(5,2) DEFAULT 18,
  amount             NUMERIC(12,2) DEFAULT 0,
  notes              TEXT,
  sort_order         INTEGER DEFAULT 0,
  created_at         TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_quotation_items_quotation_id ON quotation_items (quotation_id);
CREATE INDEX IF NOT EXISTS idx_quotation_items_service_id   ON quotation_items (service_id);

-- ============================================================
-- 10. QUOTATION SECTIONS (proposal content)
-- ============================================================
CREATE TABLE IF NOT EXISTS quotation_sections (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id             UUID NOT NULL UNIQUE REFERENCES quotations(id) ON DELETE CASCADE,
  project_overview         TEXT,
  scope_of_work            TEXT,
  deliverables             TEXT[],
  timeline                 TEXT,
  client_responsibilities  TEXT,
  exclusions               TEXT[],
  created_at               TIMESTAMPTZ DEFAULT now(),
  updated_at               TIMESTAMPTZ DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_quotation_sections_updated_at ON quotation_sections;
CREATE TRIGGER trg_quotation_sections_updated_at
  BEFORE UPDATE ON quotation_sections
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- 11. QUOTATION TERMS
-- ============================================================
CREATE TABLE IF NOT EXISTS quotation_terms (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id           UUID NOT NULL UNIQUE REFERENCES quotations(id) ON DELETE CASCADE,
  payment_terms          TEXT,
  terms_and_conditions   TEXT,
  created_at             TIMESTAMPTZ DEFAULT now(),
  updated_at             TIMESTAMPTZ DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_quotation_terms_updated_at ON quotation_terms;
CREATE TRIGGER trg_quotation_terms_updated_at
  BEFORE UPDATE ON quotation_terms
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- 12. QUOTATION STATUS HISTORY
-- ============================================================
CREATE TABLE IF NOT EXISTS quotation_status_history (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id   UUID NOT NULL REFERENCES quotations(id) ON DELETE CASCADE,
  old_status     TEXT,
  new_status     TEXT NOT NULL,
  changed_by     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  note           TEXT,
  changed_at     TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_qsh_quotation_id ON quotation_status_history (quotation_id);

-- Automatically log status changes
CREATE OR REPLACE FUNCTION log_quotation_status_change()
RETURNS TRIGGER AS $$
BEGIN
  IF (TG_OP = 'INSERT') THEN
    INSERT INTO quotation_status_history (quotation_id, old_status, new_status, changed_by)
    VALUES (NEW.id, NULL, NEW.status, NEW.created_by);
  ELSIF (TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status) THEN
    INSERT INTO quotation_status_history (quotation_id, old_status, new_status, changed_by)
    VALUES (NEW.id, OLD.status, NEW.status, auth.uid());
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_quotations_status_history ON quotations;
CREATE TRIGGER trg_quotations_status_history
  AFTER INSERT OR UPDATE ON quotations
  FOR EACH ROW EXECUTE FUNCTION log_quotation_status_change();

-- ============================================================
-- 13. QUOTATION AUDIT LOGS
-- ============================================================
CREATE TABLE IF NOT EXISTS quotation_audit_logs (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id   UUID REFERENCES quotations(id) ON DELETE CASCADE,
  action         TEXT NOT NULL, -- e.g. 'created','updated','duplicated','pdf_downloaded','deleted'
  details        JSONB,
  performed_by   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  performed_at   TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_qal_quotation_id ON quotation_audit_logs (quotation_id);

-- ============================================================
-- 14. ROW LEVEL SECURITY
-- ============================================================
ALTER TABLE profiles                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE company_settings          ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE service_categories        ENABLE ROW LEVEL SECURITY;
ALTER TABLE services                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE quotation_sequences       ENABLE ROW LEVEL SECURITY;
ALTER TABLE quotations                ENABLE ROW LEVEL SECURITY;
ALTER TABLE quotation_items           ENABLE ROW LEVEL SECURITY;
ALTER TABLE quotation_sections        ENABLE ROW LEVEL SECURITY;
ALTER TABLE quotation_terms           ENABLE ROW LEVEL SECURITY;
ALTER TABLE quotation_status_history  ENABLE ROW LEVEL SECURITY;
ALTER TABLE quotation_audit_logs      ENABLE ROW LEVEL SECURITY;

-- Single-org app: every authenticated (logged in) user shares the
-- same workspace data. Adjust these policies later if you need
-- per-user or per-role restrictions.

-- profiles
CREATE POLICY "auth_read_profiles"   ON profiles FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "self_update_profile"  ON profiles FOR UPDATE USING (auth.uid() = id);

-- company_settings
CREATE POLICY "auth_read_company_settings"   ON company_settings FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "auth_insert_company_settings" ON company_settings FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "auth_update_company_settings" ON company_settings FOR UPDATE USING (auth.role() = 'authenticated');

-- customers
CREATE POLICY "auth_read_customers"   ON customers FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "auth_insert_customers" ON customers FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "auth_update_customers" ON customers FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "auth_delete_customers" ON customers FOR DELETE USING (auth.role() = 'authenticated');

-- service_categories
CREATE POLICY "auth_read_service_categories"   ON service_categories FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "auth_insert_service_categories" ON service_categories FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "auth_update_service_categories" ON service_categories FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "auth_delete_service_categories" ON service_categories FOR DELETE USING (auth.role() = 'authenticated');

-- services
CREATE POLICY "auth_read_services"   ON services FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "auth_insert_services" ON services FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "auth_update_services" ON services FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "auth_delete_services" ON services FOR DELETE USING (auth.role() = 'authenticated');

-- quotation_sequences (read-only to clients; writes happen only via the
-- SECURITY DEFINER function get_next_quotation_number)
CREATE POLICY "auth_read_quotation_sequences" ON quotation_sequences FOR SELECT USING (auth.role() = 'authenticated');

-- quotations
CREATE POLICY "auth_read_quotations"   ON quotations FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "auth_insert_quotations" ON quotations FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "auth_update_quotations" ON quotations FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "auth_delete_quotations" ON quotations FOR DELETE USING (auth.role() = 'authenticated');

-- quotation_items
CREATE POLICY "auth_read_quotation_items"   ON quotation_items FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "auth_insert_quotation_items" ON quotation_items FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "auth_update_quotation_items" ON quotation_items FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "auth_delete_quotation_items" ON quotation_items FOR DELETE USING (auth.role() = 'authenticated');

-- quotation_sections
CREATE POLICY "auth_read_quotation_sections"   ON quotation_sections FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "auth_insert_quotation_sections" ON quotation_sections FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "auth_update_quotation_sections" ON quotation_sections FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "auth_delete_quotation_sections" ON quotation_sections FOR DELETE USING (auth.role() = 'authenticated');

-- quotation_terms
CREATE POLICY "auth_read_quotation_terms"   ON quotation_terms FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "auth_insert_quotation_terms" ON quotation_terms FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "auth_update_quotation_terms" ON quotation_terms FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "auth_delete_quotation_terms" ON quotation_terms FOR DELETE USING (auth.role() = 'authenticated');

-- quotation_status_history (append-only audit trail — no update/delete policy)
CREATE POLICY "auth_read_qsh"   ON quotation_status_history FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "auth_insert_qsh" ON quotation_status_history FOR INSERT WITH CHECK (auth.role() = 'authenticated');

-- quotation_audit_logs (append-only audit trail — no update/delete policy)
CREATE POLICY "auth_read_qal"   ON quotation_audit_logs FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "auth_insert_qal" ON quotation_audit_logs FOR INSERT WITH CHECK (auth.role() = 'authenticated');

-- ============================================================
-- 15. SEED DATA — Company settings (VSS Digital)
-- Verify these values against https://www.vssdigital.com/ and
-- correct anything here before going live — this is a starting
-- point, not a guaranteed-accurate legal record.
-- ============================================================
INSERT INTO company_settings (
  company_name, tagline, address, city, state, country, postcode,
  phone, phone_alt, email, website, gstin,
  default_currency, default_validity_days, default_gst_rate, quotation_prefix,
  footer_text
)
SELECT
  'VSS Digital',
  'Digital Marketing & Digital Growth Solutions',
  'HIG-24, 1st Cross, Navanagar',
  'Hubballi, Dharwad',
  'Karnataka',
  'India',
  '580025',
  '+91 6204070811',
  '+44 7771698669',
  'info@vssdigital.com',
  'https://www.vssdigital.com/',
  '29COKPA0309E1ZE',
  'INR',
  15,
  18,
  'VSSD-Q',
  'Helping startups, MSMEs and growing brands scale online.'
WHERE NOT EXISTS (SELECT 1 FROM company_settings);

-- ============================================================
-- 16. SEED DATA — Service categories
-- ============================================================
INSERT INTO service_categories (name, description, sort_order) VALUES
  ('SEO', 'Search engine optimization services', 1),
  ('Social Media Marketing', 'Social media management and strategy', 2),
  ('PPC & Google Ads', 'Paid search and display advertising on Google', 3),
  ('Meta Ads', 'Paid advertising on Facebook and Instagram', 4),
  ('Content Marketing', 'Content strategy, writing and creation', 5),
  ('Website Development', 'Website design, development and maintenance', 6),
  ('Branding & Design', 'Brand identity and creative design', 7),
  ('E-commerce Marketing', 'E-commerce specific marketing and optimization', 8),
  ('Performance Marketing', 'Cross-channel performance and conversion optimization', 9)
ON CONFLICT (name) DO NOTHING;

-- ============================================================
-- 17. SEED DATA — Example services
-- Prices are seeded as 0 (configurable) since no official VSS
-- Digital price list was provided. Update via the Services page
-- or directly in this table once real pricing is confirmed.
-- ============================================================
INSERT INTO services (category_id, name, description, default_price, billing_frequency, unit, tax_rate)
SELECT c.id, s.name, s.description, 0, s.freq, s.unit, 18
FROM (VALUES
  ('SEO','SEO Audit','Comprehensive audit of on-page, technical and off-page SEO health.','One Time','Project'),
  ('SEO','Keyword Research','In-depth keyword and competitor research.','One Time','Project'),
  ('SEO','On-page SEO','On-page optimization of meta tags, content and site structure.','One Time','Project'),
  ('SEO','Technical SEO','Technical fixes for crawlability, indexing and site speed.','One Time','Project'),
  ('SEO','Off-page SEO','Backlink and authority-building activities.','Monthly','Month'),
  ('SEO','Link Building','Outreach-based link building campaign.','Monthly','Month'),
  ('SEO','Local SEO','Google Business Profile and local search optimization.','Monthly','Month'),
  ('SEO','Monthly SEO Management','Ongoing SEO management, reporting and optimization.','Monthly','Month'),
  ('Social Media Marketing','Social Media Strategy','Platform strategy and content calendar planning.','One Time','Project'),
  ('Social Media Marketing','Instagram Management','Ongoing Instagram content, posting and engagement.','Monthly','Month'),
  ('Social Media Marketing','Facebook Management','Ongoing Facebook page management and posting.','Monthly','Month'),
  ('Social Media Marketing','LinkedIn Management','Ongoing LinkedIn company page management.','Monthly','Month'),
  ('Social Media Marketing','Social Media Management','Full-service management across social channels.','Monthly','Month'),
  ('Social Media Marketing','Monthly Social Media Package','Content, posting and reporting bundle.','Monthly','Package'),
  ('PPC & Google Ads','Google Ads Management','Setup and ongoing management of Google Ads campaigns.','Monthly','Month'),
  ('PPC & Google Ads','PPC Campaign Management','Ongoing pay-per-click campaign management.','Monthly','Month'),
  ('PPC & Google Ads','Google Search Ads','Search campaign setup and optimization.','Monthly','Campaign'),
  ('PPC & Google Ads','Display Ads','Display network campaign setup and management.','Monthly','Campaign'),
  ('PPC & Google Ads','Remarketing','Remarketing/retargeting campaign setup.','Monthly','Campaign'),
  ('PPC & Google Ads','Lead Generation Campaign','End-to-end lead generation campaign management.','Monthly','Campaign'),
  ('Meta Ads','Meta Ads Management','Ongoing Facebook & Instagram ads management.','Monthly','Month'),
  ('Meta Ads','Facebook Ads Campaign','Campaign setup and optimization on Facebook.','Monthly','Campaign'),
  ('Meta Ads','Instagram Ads Campaign','Campaign setup and optimization on Instagram.','Monthly','Campaign'),
  ('Content Marketing','Blog Writing','SEO-friendly blog articles.','Monthly','Package'),
  ('Content Marketing','SEO Content Writing','Website and landing page content optimized for search.','One Time','Page'),
  ('Content Marketing','Social Media Content','Copy and captions for social media posts.','Monthly','Package'),
  ('Content Marketing','Website Content','Full website copywriting.','One Time','Project'),
  ('Content Marketing','Content Strategy','Content planning and editorial calendar.','One Time','Project'),
  ('Content Marketing','Creative Content','Creative campaign content development.','One Time','Project'),
  ('Website Development','Landing Page','Single conversion-focused landing page.','One Time','Page'),
  ('Website Development','Business Website','Multi-page business website.','One Time','Project'),
  ('Website Development','Corporate Website','Full corporate website with CMS.','One Time','Project'),
  ('Website Development','E-commerce Website','Online store setup with payment/shipping integration.','One Time','Project'),
  ('Website Development','Website Redesign','Redesign of an existing website.','One Time','Project'),
  ('Website Development','Website Maintenance','Ongoing website updates, backups and support.','Monthly','Month'),
  ('Branding & Design','Logo Design','Custom logo design with revisions.','One Time','Project'),
  ('Branding & Design','Brand Identity','Full brand identity including colours, typography and guidelines.','One Time','Package'),
  ('Branding & Design','Social Media Creatives','Branded creative templates for social posts.','Monthly','Package'),
  ('Branding & Design','Brochure Design','Print or digital brochure design.','One Time','Project'),
  ('Branding & Design','Business Profile','Company profile / capability deck design.','One Time','Project'),
  ('Branding & Design','Branding Package','Bundled logo, identity and collateral design.','One Time','Package'),
  ('E-commerce Marketing','E-commerce SEO','SEO tailored for online stores and product pages.','Monthly','Month'),
  ('E-commerce Marketing','E-commerce Marketing','Cross-channel marketing for online stores.','Monthly','Month'),
  ('E-commerce Marketing','Product Listing Optimization','Optimization of product titles, images and descriptions.','One Time','Package'),
  ('Performance Marketing','Performance Marketing Package','Cross-channel paid performance management.','Monthly','Month'),
  ('Performance Marketing','Conversion Rate Optimization','Landing page and funnel CRO.','One Time','Project'),
  ('Performance Marketing','Analytics & Tracking Setup','GA4, tag manager and conversion tracking setup.','One Time','Project')
) AS s(cat, name, description, freq, unit)
JOIN service_categories c ON c.name = s.cat
WHERE NOT EXISTS (
  SELECT 1 FROM services sv WHERE sv.name = s.name
);

-- ============================================================
-- Done! Next steps:
-- 1. In your VSS Digital Supabase project, run this whole file
--    once in the SQL Editor.
-- 2. Create at least one login user under Authentication > Users
--    (or enable sign-up in index.html) so you can sign in.
-- 3. Copy the Project URL and anon public key from
--    Project Settings > API into index.html.
-- ============================================================
