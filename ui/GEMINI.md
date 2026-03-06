# Gemini Project Analysis

## Project Overview

This is a full-stack TypeScript application with a React frontend and an Express backend. The project is set up with Vite for both the client and server builds. It also uses Netlify for deployment.

**Frontend:**

*   **Framework:** React
*   **Language:** TypeScript
*   **Build Tool:** Vite
*   **UI:** shadcn/ui
*   **Routing:** react-router-dom
*   **Data Fetching:** @tanstack/react-query

**Backend:**

*   **Framework:** Express
*   **Language:** TypeScript
*   **Build Tool:** Vite

## Building and Running

*   **Development:** `npm run dev`
*   **Build:** `npm run build`
*   **Start:** `npm run start`
*   **Test:** `npm run test`
*   **Typecheck:** `npm run typecheck`

## Development Conventions

*   The project uses Prettier for code formatting. Use `npm run format.fix` to format the code.
*   The project uses aliases for imports: `@` for `client` and `@shared` for `shared`.
*   The project uses `vitest` for testing.
