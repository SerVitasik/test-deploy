## Starting the application

Install dependencies:

```bash
npm ci
```

Migrate the database:

```bash
npm run migrateLocal
```

Start the server:

```bash
npm start
```

## Changing schema

Open `schema.prisma` and change schema as needed: add new tables, columns, etc (See [Prisma schema reference](https://www.prisma.io/docs/reference/tools-and-interfaces/prisma-schema)).

Run the following command to generate a new migration and apply it instantly in local database:

```bash
npm run makemigration -- --name <name_of_changes>
```

Your colleagues will need to pull the changes and run `npm run migrateLocal` to apply the migration in their local database.

## Documentation

- [Customizing AdminForth Branding](https://adminforth.dev/docs/tutorial/Customization/branding/)
- [Custom Field Rendering](https://adminforth.dev/docs/tutorial/Customization/customFieldRendering/)
- [Hooks](https://adminforth.dev/docs/tutorial/Customization/hooks/)
- [Custom Pages](https://adminforth.dev/docs/tutorial/Customization/customPages/)
