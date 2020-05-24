﻿DROP TYPE STREAMNEWMESSAGES;
/
DROP TYPE STREAMDELETEDMESSAGES;
/
CREATE OR REPLACE TYPE STREAMNEWMESSAGE IS OBJECT
(
    ID              VARCHAR2(40),
    "TYPE"          NVARCHAR2(128),
    "Created"       TIMESTAMP,
    JSONDATA        NCLOB,
    JSONMETA        NCLOB
);
/
CREATE OR REPLACE TYPE STREAMNEWMESSAGES IS TABLE OF STREAMNEWMESSAGE;
/
CREATE OR REPLACE TYPE STREAMDELETEDMESSAGE IS OBJECT
(
    ID               VARCHAR2(40),
    StreamIdOriginal NVARCHAR2(1000)
);
/
CREATE OR REPLACE TYPE STREAMDELETEDMESSAGES IS TABLE OF STREAMDELETEDMESSAGE;
/
CREATE OR REPLACE TYPE STREAMAPPENDED IS OBJECT
(
    CURRENTVERSION NUMBER(10),
    CURRENTPOSITION INT
);
/
CREATE OR REPLACE PACKAGE StreamStore AS
    e_wrong_version EXCEPTION;
    PRAGMA exception_init( e_wrong_version, -20001 );

    e_wrong_expected_version EXCEPTION;
    PRAGMA exception_init( e_wrong_expected_version, -20002 );

    e_duplicate_messageid EXCEPTION;
    PRAGMA exception_init( e_duplicate_messageid, -20003 );

    PROCEDURE READ(
        P_StreamId IN CHAR,
        P_Count    IN  NUMBER,
        P_Version  IN  NUMBER,
        P_Forwards IN  NUMBER,
        P_Prefetch IN  NUMBER,
        oStreamInfo OUT SYS_REFCURSOR,
        oStreamEvents OUT SYS_REFCURSOR
    );

    PROCEDURE READALL(
        P_Position IN INT,
        P_Count    IN  NUMBER,
        P_Forwards IN  NUMBER,
        P_Prefetch IN  NUMBER,
        oEvents OUT SYS_REFCURSOR
    );

    FUNCTION APPEND(
        P_StreamId           in CHAR,
        P_MetaStreamId           in CHAR,
        P_StreamIdOriginal   in NVARCHAR2,
        P_ExpectedVersion    in NUMBER,
        P_NewStreamMessages in STREAMNEWMESSAGES)
        RETURN STREAMAPPENDED;

    PROCEDURE DELETESTREAM_EXPECTEDVERSION(
        P_StreamId           in CHAR,
        P_MetaStreamId           in CHAR,
        P_ExpectedVersion    in NUMBER,
        oDeletedStream      OUT NUMBER,
        oDeletedMetaStream  OUT NUMBER);

    PROCEDURE DELETESTREAM_ANYVERSION(
        P_StreamId           in CHAR,
        P_MetaStreamId           in CHAR,
        oDeletedStream      OUT NUMBER,
        oDeletedMetaStream  OUT NUMBER);

    PROCEDURE SETMETA(
        P_StreamId           in CHAR,
        P_MetaStreamId           in CHAR,
        P_MaxAge            IN NUMBER,
        P_MaxCount            IN NUMBER
    );

END StreamStore;
/
CREATE OR REPLACE PACKAGE BODY StreamStore AS



    PROCEDURE READ(
        P_StreamId IN CHAR,
        P_Count    IN  NUMBER,
        P_Version  IN  NUMBER,
        P_Forwards IN  NUMBER,
        P_Prefetch IN  NUMBER,
        oStreamInfo OUT SYS_REFCURSOR,
        oStreamEvents OUT SYS_REFCURSOR
    )
        IS
    BEGIN
        OPEN oStreamInfo FOR
            SELECT STREAMS.Version,
                   STREAMS.Position,
                   STREAMS.MaxAge,
                   STREAMS.MaxCount
            FROM STREAMS
            WHERE STREAMS.ID = P_StreamId;

        OPEN oStreamEvents FOR
            SELECT STREAMS.IDORIGINAL AS StreamId,
                   STREAMEVENTS.ID,
                   STREAMEVENTS.STREAMVERSION,
                   STREAMEVENTS.Position,
                   STREAMEVENTS.Created,
                   STREAMEVENTS.Type,
                   STREAMEVENTS.JSONMETA,
                   (CASE P_Prefetch
                        WHEN 1 THEN STREAMEVENTS.JSONDATA
                        ELSE NULL END) AS JsonData
            FROM STREAMEVENTS
                     INNER JOIN STREAMS ON STREAMS.IDINTERNAL = STREAMEVENTS.STREAMIDINTERNAL
            WHERE
                    STREAMS.ID = P_StreamId AND
                    CASE
                        WHEN P_Forwards = 1 AND STREAMEVENTS.StreamVersion >= P_Version
                            THEN 1
                        WHEN P_Forwards = 0 AND STREAMEVENTS.StreamVersion <= P_version
                            THEN 1
                        ELSE 0
                        END = 1
            ORDER BY (CASE
                          WHEN P_forwards = 1
                              THEN STREAMEVENTS.StreamVersion
                          ELSE   STREAMEVENTS.StreamVersion * -1
                END)
                OFFSET 0 ROWS FETCH FIRST P_count ROWS ONLY
        ;
    END;

    PROCEDURE READALL(
        P_Position IN INT,
        P_Count    IN  NUMBER,
        P_Forwards IN  NUMBER,
        P_Prefetch IN  NUMBER,
        oEvents OUT SYS_REFCURSOR
    )
        IS
    BEGIN

        OPEN oEvents FOR
            SELECT STREAMS.IDORIGINAL AS StreamId,
                   STREAMS.MAXAGE,
                   STREAMEVENTS.ID,
                   STREAMEVENTS.STREAMVERSION,
                   STREAMEVENTS.Position,
                   STREAMEVENTS.Created,
                   STREAMEVENTS.Type,
                   STREAMEVENTS.JSONMETA,
                   (CASE P_Prefetch
                        WHEN 1 THEN STREAMEVENTS.JSONDATA
                        ELSE NULL END) AS JSONDATA
            FROM STREAMEVENTS
                     INNER JOIN STREAMS ON STREAMS.IDINTERNAL = STREAMEVENTS.STREAMIDINTERNAL
            WHERE
                    CASE
                        WHEN P_Forwards = 1 AND STREAMEVENTS.Position >= P_Position
                            THEN 1
                        WHEN P_Forwards = 0 AND STREAMEVENTS.Position <= P_Position
                            THEN 1
                        ELSE 0
                        END = 1
            ORDER BY (CASE
                          WHEN P_forwards = 1
                              THEN STREAMEVENTS.Position
                          ELSE   STREAMEVENTS.Position * -1
                END)
                OFFSET 0 ROWS FETCH FIRST P_count ROWS ONLY
        ;
    END;

    FUNCTION CREATESTREAM(
        P_StreamId           in CHAR,
        P_MetaStreamId           in CHAR,
        P_StreamIdOriginal   in NVARCHAR2
    ) return NUMBER
        IS
        V_MaxAge NUMBER(10);
        V_MaxCount NUMBER(10);
        V_StreamIdInternal NUMBER(10);
    BEGIN
        BEGIN
            SELECT STREAMS.MaxAge, STREAMS.MaxCount
            INTO V_MaxAge, V_Maxcount
            FROM STREAMS
            WHERE STREAMS.ID = P_MetaStreamId;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN NULL;
        END;

        BEGIN
            INSERT INTO STREAMS (Id, IdOriginal, MaxAge, MaxCount)
            VALUES (P_StreamId, P_StreamIdOriginal, V_MaxAge, V_MaxCount)
            RETURNING IDINTERNAL INTO V_StreamIdInternal;
        EXCEPTION
            /* Allow insert to fail */
            WHEN dup_val_on_index THEN RETURN NULL;
        END;

        RETURN V_StreamIdInternal;
    END;


    PROCEDURE ENSUREAPPENDEVENTSIDEMPOTENT(
        P_StreamInternalId          IN NUMBER,
        P_StartPos          IN INT,
        P_CheckLength       IN NUMBER,
        NewStreamMessages   IN STREAMNEWMESSAGES)
        IS

        TYPE ArrayString IS TABLE OF VARCHAR2(40);

        V_EXISTING_EVENT_IDS ArrayString;
        V_MESSAGE_COUNT NUMBER;

    BEGIN

        V_MESSAGE_COUNT := NewStreamMessages.count;

        SELECT STREAMEVENTS.ID
            BULK COLLECT INTO V_EXISTING_EVENT_IDS
        FROM STREAMEVENTS
        WHERE STREAMEVENTS.STREAMIDINTERNAL = P_StreamInternalId AND STREAMEVENTS.StreamVersion > P_StartPos
        ORDER BY STREAMEVENTS.StreamVersion ASC
            OFFSET 0 ROWS FETCH FIRST V_MESSAGE_COUNT ROWS ONLY;

        IF (P_CheckLength = 1 AND NewStreamMessages.count != V_EXISTING_EVENT_IDS.count)
        THEN
            RAISE e_wrong_version;
        END IF;

        FOR i IN NewStreamMessages.FIRST .. NewStreamMessages.LAST
            LOOP
                IF (NewStreamMessages(i).ID != V_EXISTING_EVENT_IDS(i))
                THEN
                    RAISE e_wrong_version;
                END IF;
            END LOOP;
    END;

    FUNCTION APPEND_EXPECTEDVERSION(
        P_StreamId           in CHAR,
        P_ExpectedVersion    in NUMBER,
        P_NewStreamMessages in STREAMNEWMESSAGES)
        RETURN STREAMAPPENDED
    AS

        V_StreamVersion    NUMBER(10);
        V_StreamIdInternal  NUMBER(10);
        V_LatestPosition     INT;
        V_LatestVersion   NUMBER(10);
        V_NewMessage      STREAMNEWMESSAGE;
        V_InsertedCount NUMBER(10);
    BEGIN
        BEGIN
            SELECT STREAMS.IdInternal, STREAMS.Version, STREAMS.Position
            INTO V_StreamIdInternal, V_StreamVersion, V_LatestPosition
            FROM STREAMS
            WHERE STREAMS.Id = P_StreamId
                FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN RAISE e_wrong_version;
        END;

        /* Stream should exist */
        IF (V_StreamIdInternal IS NULL)
        THEN
            RAISE e_wrong_version;
        END IF;

        /* Expected version should match current version */
        IF (V_StreamVersion <> P_ExpectedVersion)
        THEN
            /* IDEMPOTENCY */
            /* If it doesn't, maybe these message were already appended at the expected version */
            /* This will throw if they were not.. */
            ENSUREAPPENDEVENTSIDEMPOTENT(
                    V_StreamIdInternal,
                    P_ExpectedVersion,
                    1,
                    P_NewStreamMessages);

            /* .. or return to allow us to confirm */
            RETURN STREAMAPPENDED(V_StreamVersion, V_LatestPosition);
        END IF;

        IF (P_NewStreamMessages.COUNT <= 0) THEN
            RETURN STREAMAPPENDED(V_StreamVersion, V_LatestPosition);
        END IF;

        V_LatestVersion := V_StreamVersion;
        V_InsertedCount := 0;
        BEGIN
            FOR V_i IN P_NewStreamMessages.FIRST .. P_NewStreamMessages.LAST
                LOOP
                    V_LatestVersion := V_LatestVersion + 1;
                    V_NewMessage := P_NewStreamMessages(V_i);
                    INSERT INTO STREAMEVENTS (STREAMIDINTERNAL, STREAMVERSION, ID, TYPE, JSONDATA, JSONMETA, CREATED)
                    VALUES (V_StreamIdInternal, V_LatestVersion, V_NewMessage.Id, V_NewMessage.Type, V_NewMessage.JsonData, V_NewMessage.JsonMeta, CASE WHEN V_NewMessage."Created" IS NULL THEN sys_extract_utc(systimestamp) ELSE V_NewMessage."Created" END)
                    RETURNING STREAMEVENTS.Position INTO V_LatestPosition;
                END LOOP;

            UPDATE STREAMS
            SET STREAMS.Version = V_LatestVersion,
                STREAMS.Position = V_LatestPosition
            WHERE STREAMS.IdInternal = V_StreamIdInternal;

            RETURN STREAMAPPENDED(V_LatestVersion, V_LatestPosition);
        EXCEPTION
            WHEN dup_val_on_index THEN NULL;
        END;

        /* If any record was inserted, there is no chance this can result in an idempotent insert */
        IF (V_InsertedCount > 0)
        THEN
            RAISE e_duplicate_messageid;
        END IF;


        /* IDEMPOTENCY */
        /* If it doesn't, maybe these message were already appended at the expected version */
        /* This will throw if they were not.. */
        ENSUREAPPENDEVENTSIDEMPOTENT(
                V_StreamIdInternal,
                P_ExpectedVersion,
                1,
                P_NewStreamMessages);

        SELECT STREAMS.Version, STREAMS.Position
        INTO V_StreamVersion, V_LatestPosition
        FROM STREAMS
        WHERE STREAMS.Id = P_StreamId;

        RETURN STREAMAPPENDED(V_StreamVersion, V_LatestPosition);
    END;

    FUNCTION APPEND_NOSTREAM(
        P_StreamId           in CHAR,
        P_MetaStreamId           in CHAR,
        P_StreamIdOriginal   in NVARCHAR2,
        P_NewStreamMessages in STREAMNEWMESSAGES)
        RETURN STREAMAPPENDED
    AS
        AppendedResult STREAMAPPENDED;

        V_StreamIdInternal NUMBER(10);
        V_MaxAge NUMBER(10);
        V_MaxCount NUMBER(10);
    BEGIN

        V_StreamIdInternal := CREATESTREAM(P_StreamId, P_MetaStreamId, P_StreamIdOriginal);

        /* IDEMPOTENCY */
        /* Insert failed but could still contain the messages to be persisted */
        IF (V_StreamIdInternal IS NULL)
        THEN

            SELECT STREAMS.IDINTERNAL INTO V_StreamIdInternal FROM STREAMS WHERE STREAMS.Id = P_StreamId;

            /* IDEMPOTENCY */
            /* If it doesn't, maybe these message were already appended at the expected version */
            /* This will throw if they were not.. */
            ENSUREAPPENDEVENTSIDEMPOTENT(
                    V_StreamIdInternal,
                    -1,
                    1,
                    P_NewStreamMessages);

            /* .. or return to allow us to confirm */
            SELECT STREAMAPPENDED(STREAMS.Version, STREAMS.Position)
            INTO AppendedResult
            FROM STREAMS
            WHERE STREAMS.IdInternal = V_StreamIdInternal;

            RETURN AppendedResult;

        END IF;

        IF (P_NewStreamMessages.COUNT <= 0) THEN
            RETURN STREAMAPPENDED(-1, -1);
        END IF;

        /* Continue with append with expected version zero */
        RETURN APPEND_EXPECTEDVERSION(P_StreamId, -1, P_NewStreamMessages);

    END;

    FUNCTION APPEND_ANYVERSION(
        P_StreamId           in CHAR,
        P_MetaStreamId           in CHAR,
        P_StreamIdOriginal   in NVARCHAR2,
        P_NewStreamMessages in STREAMNEWMESSAGES)
        RETURN STREAMAPPENDED
    AS
        V_StreamIdInternal NUMBER(10);
        V_Created NUMBER(10);
        V_MaxAge NUMBER(10);
        V_MaxCount NUMBER(10);
        V_LatestPosition INT;
        V_LatestVersion NUMBER(10);
        V_NewMessage      STREAMNEWMESSAGE;
        V_Deleted           STREAMDELETEDMESSAGES;
        V_InsertedCount NUMBER(10);
    BEGIN

        V_StreamIdInternal := CREATESTREAM(P_StreamId, P_MetaStreamId, P_StreamIdOriginal);

        SELECT STREAMS.IdInternal, STREAMS.Version, STREAMS.Position
        INTO V_StreamIdInternal, V_LatestVersion, V_LatestPosition
        FROM STREAMS
        WHERE STREAMS.Id = P_StreamId
            FOR UPDATE;

        IF (P_NewStreamMessages.count <= 0)
        THEN
            RETURN STREAMAPPENDED(V_LatestVersion, V_LatestPosition);
        END IF;

        V_InsertedCount := 0;
        BEGIN

            FOR V_i IN P_NewStreamMessages.FIRST .. P_NewStreamMessages.LAST
                LOOP
                    V_NewMessage := P_NewStreamMessages(V_i);
                    INSERT INTO STREAMEVENTS (STREAMIDINTERNAL, STREAMVERSION, ID, TYPE, JSONDATA, JSONMETA, CREATED)
                    VALUES (V_StreamIdInternal, V_LatestVersion + 1, V_NewMessage.Id, V_NewMessage.Type, V_NewMessage.JsonData, V_NewMessage.JsonMeta, CASE WHEN V_NewMessage."Created" IS NULL THEN sys_extract_utc(systimestamp) ELSE V_NewMessage."Created" END)
                    RETURNING STREAMEVENTS.Position INTO V_LatestPosition;

                    V_InsertedCount := V_InsertedCount + 1;
                    V_LatestVersion := V_LatestVersion + 1;
                END LOOP;

            UPDATE STREAMS
            SET STREAMS.Version = V_LatestVersion,
                STREAMS.Position = V_LatestPosition
            WHERE STREAMS.IdInternal = V_StreamIdInternal;

            RETURN STREAMAPPENDED(V_LatestVersion, V_LatestPosition);

        EXCEPTION
            WHEN dup_val_on_index THEN NULL;
        END;

        /* If any record was inserted, there is no chance this can result in an idempotent insert */
        IF (V_InsertedCount > 0)
        THEN
            RAISE e_duplicate_messageid;
        END IF;

        DECLARE
            l_VersionTocheck NUMBER(10);
            l_FirstMessage STREAMNEWMESSAGE;
        BEGIN
            l_FirstMessage := P_NewStreamMessages(1);

            /* Find the version of the first message */
            /* Start check from there */
            SELECT StreamVersion INTO l_VersionTocheck FROM STREAMEVENTS WHERE Id = l_FirstMessage.Id;

            /* IDEMPOTENCY */
            /* If it doesn't, maybe these message were already appended at the expected version */
            /* This will throw if they were not.. */
            ENSUREAPPENDEVENTSIDEMPOTENT(
                    V_StreamIdInternal,
                    l_VersionTocheck - 1,
                    1,
                    P_NewStreamMessages);
        END;

        RETURN STREAMAPPENDED(V_LatestVersion, V_LatestPosition);
    END;

    FUNCTION APPEND_INTERNAL(
        P_StreamId           in CHAR,
        P_MetaStreamId           in CHAR,
        P_StreamIdOriginal   in NVARCHAR2,
        P_ExpectedVersion    in NUMBER,
        P_NewStreamMessages in STREAMNEWMESSAGES)
        RETURN STREAMAPPENDED
        IS
    BEGIN

        IF (P_ExpectedVersion = -2)
        THEN
            RETURN APPEND_ANYVERSION(P_StreamId, P_MetaStreamId, P_StreamIdOriginal, P_NewStreamMessages);
        ELSIF (P_ExpectedVersion = -3)
        THEN
            RETURN APPEND_NOSTREAM(P_StreamId, P_MetaStreamId, P_StreamIdOriginal, P_NewStreamMessages);
        END IF;

        RETURN APPEND_EXPECTEDVERSION(P_StreamId, P_ExpectedVersion, P_NewStreamMessages);

    END;

    PROCEDURE TRUNCATE(
        P_StreamId IN CHAR
    )
        IS
        V_StreamIdOriginal VARCHAR(1000);
        V_StreamIdInternal  NUMBER(10);
        V_MaxCount          NUMBER(10);
        V_Count             INT;
        V_DeletedMessages   STREAMNEWMESSAGES;
        V_Result    STREAMAPPENDED;
    BEGIN
        BEGIN
            SELECT MaxCount, IdOriginal, IdInternal INTO V_MaxCount, V_StreamIdOriginal, V_StreamIdInternal FROM STREAMS WHERE STREAMS.ID = P_StreamId;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN RETURN;
        END;

        IF (V_MaxCount IS NULL)
        THEN
            RETURN;
        END IF;

        BEGIN
            SELECT COUNT(Id) INTO V_Count FROM STREAMEVENTS WHERE STREAMEVENTS.STREAMIDINTERNAL = V_StreamIdInternal;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN RETURN;
        END;

        IF (V_Count <= V_MaxCount)
        THEN
            RETURN;
        END IF;

        DELETE FROM STREAMEVENTS
        WHERE STREAMEVENTS.ID IN (SELECT STREAMEVENTS.ID FROM STREAMEVENTS
                                  WHERE STREAMEVENTS.StreamIdInternal = V_StreamIdInternal
                                  ORDER BY STREAMEVENTS.POSITION ASC
                                      OFFSET 0 ROWS FETCH FIRST (V_Count - V_MaxCount) ROWS ONLY
        )
        RETURNING STREAMNEWMESSAGE(NULL, '$message-deleted', NULL, '{"StreamId":"' || V_StreamIdOriginal || '","MessageId":"' || STREAMEVENTS.ID || '"}', NULL)
            BULK COLLECT INTO V_DeletedMessages;

        V_Result := APPEND_INTERNAL('3A6B2F0A2C8DE85A87ACD69A74E8B58B0233C7AA', '92C1448CD20ED4210BBF4BBCDC4952FCE917D145', '$deleted', -2, V_DeletedMessages);

    END;

    FUNCTION APPEND(
        P_StreamId           in CHAR,
        P_MetaStreamId           in CHAR,
        P_StreamIdOriginal   in NVARCHAR2,
        P_ExpectedVersion    in NUMBER,
        P_NewStreamMessages in STREAMNEWMESSAGES)
        RETURN STREAMAPPENDED
        IS
        V_Result    STREAMAPPENDED;
    BEGIN

        V_Result := APPEND_INTERNAL(P_StreamId, P_MetaStreamId, P_StreamIdOriginal, P_ExpectedVersion, P_NewStreamMessages);

        TRUNCATE(P_StreamId);

        return V_Result;

    END;

    PROCEDURE DELETESTREAM_EXPECTEDVERSION(
        P_StreamId           in CHAR,
        P_MetaStreamId           in CHAR,
        P_ExpectedVersion    in NUMBER,
        oDeletedStream      OUT NUMBER,
        oDeletedMetaStream  OUT NUMBER)
        IS
        V_StreamIdInternal  NUMBER(10);
    BEGIN
        BEGIN
            SELECT STREAMS.IdInternal INTO V_StreamIdInternal FROM STREAMS
            WHERE STREAMS.Id = P_StreamId AND STREAMS.Version = P_ExpectedVersion
                FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN RAISE e_wrong_version;
        END;

        DELETE FROM STREAMEVENTS WHERE STREAMEVENTS.STREAMIDINTERNAL = V_StreamIdInternal;
        DELETE FROM STREAMS WHERE STREAMS.IDINTERNAL = V_StreamIdInternal;

        oDeletedStream := sql%ROWCOUNT;

        DELETE FROM STREAMEVENTS WHERE STREAMEVENTS.STREAMIDINTERNAL IN (SELECT STREAMS.IDINTERNAL FROM STREAMS WHERE STREAMS.ID = P_MetaStreamId);
        DELETE FROM STREAMS WHERE STREAMS.ID = P_MetaStreamId;

        oDeletedMetaStream := sql%ROWCOUNT;

    END;

    PROCEDURE DELETESTREAM_ANYVERSION(
        P_StreamId           in CHAR,
        P_MetaStreamId           in CHAR,
        oDeletedStream      OUT NUMBER,
        oDeletedMetaStream  OUT NUMBER)
        IS
    BEGIN

        DELETE FROM STREAMEVENTS WHERE STREAMEVENTS.STREAMIDINTERNAL IN (SELECT STREAMS.IDINTERNAL FROM STREAMS WHERE STREAMS.ID = P_StreamId);
        DELETE FROM STREAMS WHERE STREAMS.ID = P_StreamId;

        oDeletedStream := sql%ROWCOUNT;

        DELETE FROM STREAMEVENTS WHERE STREAMEVENTS.STREAMIDINTERNAL IN (SELECT STREAMS.IDINTERNAL FROM STREAMS WHERE STREAMS.ID = P_MetaStreamId);
        DELETE FROM STREAMS WHERE STREAMS.ID = P_MetaStreamId;

        oDeletedMetaStream := sql%ROWCOUNT;

    END;

    PROCEDURE SETMETA(
        P_StreamId           in CHAR,
        P_MetaStreamId           in CHAR,
        P_MaxAge            IN NUMBER,
        P_MaxCount            IN NUMBER
    )
        IS
        V_StreamIdInternal  NUMBER(10);
        V_StreamIdOriginal  NVARCHAR2(1000);
    BEGIN

        UPDATE STREAMS SET STREAMS.MaxAge = P_MaxAge, STREAMS.MaxCount = P_MaxCount WHERE STREAMS.Id = P_MetaStreamid;

        BEGIN
            UPDATE STREAMS SET STREAMS.MaxAge = P_MaxAge, STREAMS.MaxCount = P_MaxCount WHERE STREAMS.Id = P_StreamId
            RETURNING STREAMS.IDINTERNAL, STREAMS.IDORIGINAL into V_StreamIdInternal, V_StreamIdOriginal;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN RETURN;
        END;

        IF (P_MaxCount IS NULL)
        THEN
            RETURN;
        END IF;

        TRUNCATE(P_StreamId);

    END;
END StreamStore;